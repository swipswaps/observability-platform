#!/usr/bin/env python3
# PATH: scripts/journal_ingester.py
import json
import subprocess
import psycopg2
import time
import os
import sys
from pathlib import Path
from datetime import datetime

CURSOR_FILE = Path('/var/lib/observability/journal_cursor')
DEAD_LETTER_FILE = Path('/var/lib/observability/dead_letter.jsonl')
DB_DSN = os.getenv('DB_DSN', 'dbname=observability user=observer password=observer host=localhost')

print(f"=== Journal Ingester Starting ===", file=sys.stderr, flush=True)
print(f"DB_DSN: {DB_DSN.replace('password=observer', 'password=***')}", file=sys.stderr, flush=True)

def backoff(attempt):
    wait = min(60, 2 ** attempt)
    print(f"Backing off for {wait}s (attempt {attempt})", file=sys.stderr, flush=True)
    time.sleep(wait)

def get_cursor():
    if CURSOR_FILE.exists():
        cursor = CURSOR_FILE.read_text().strip()
        print(f"Loaded cursor: {cursor[:50]}...", file=sys.stderr, flush=True)
        return cursor
    return None

def save_cursor(cursor):
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(cursor)

def append_dead_letter(entry):
    DEAD_LETTER_FILE.parent.mkdir(parents=True, exist_ok=True)
    with DEAD_LETTER_FILE.open('a') as f:
        f.write(json.dumps(entry) + '\n')
    print(f"Wrote to dead letter", file=sys.stderr, flush=True)

def parse_journal_entry(line):
    try:
        entry = json.loads(line)
        return {
            'time': datetime.fromtimestamp(int(entry.get('__REALTIME_TIMESTAMP', 0)) / 1000000.0),
            'host': os.uname().nodename,
            'pid': entry.get('_PID'),
            'event_type': 'journal',
            'severity': entry.get('PRIORITY', '6'),
            'subsystem': entry.get('_SYSTEMD_UNIT', 'unknown'),
            'message': entry.get('MESSAGE', ''),
            'raw_payload': entry
        }
    except (json.JSONDecodeError, ValueError) as e:
        print(f"Parse error: {e}", file=sys.stderr, flush=True)
        return None

def ingest():
    attempt = 0
    while True:
        try:
            print(f"Connecting to database (attempt {attempt})...", file=sys.stderr, flush=True)
            conn = psycopg2.connect(DB_DSN)
            cur = conn.cursor()
            
            cmd = ['journalctl', '-f', '-o', 'json', '--output-fields=__REALTIME_TIMESTAMP,MESSAGE,PRIORITY,_PID,_SYSTEMD_UNIT,__CURSOR']
            
            cursor = get_cursor()
            if cursor:
                cmd.extend(['--after-cursor', cursor])
                print(f"Resuming from cursor", file=sys.stderr, flush=True)
            else:
                print("Starting from beginning", file=sys.stderr, flush=True)
            
            print(f"Starting journalctl: {' '.join(cmd)}", file=sys.stderr, flush=True)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            
            print("Connected - streaming journal...", file=sys.stderr, flush=True)
            attempt = 0
            
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                
                event = parse_journal_entry(line)
                if not event:
                    continue
                
                try:
                    cur.execute("""
                        INSERT INTO events (time, host, pid, event_type, severity, subsystem, message, raw_payload)
                        VALUES (%(time)s, %(host)s, %(pid)s, %(event_type)s, %(severity)s, %(subsystem)s, %(message)s, %(raw_payload)s)
                    """, event)
                    conn.commit()
                    
                    if '__CURSOR' in event['raw_payload']:
                        save_cursor(event['raw_payload']['__CURSOR'])
                        
                except psycopg2.Error as e:
                    print(f"DB error: {e}", file=sys.stderr, flush=True)
                    append_dead_letter(event)
                    conn.rollback()
            
        except (psycopg2.OperationalError, ConnectionError) as e:
            print(f"Connection error: {e}", file=sys.stderr, flush=True)
            attempt += 1
            backoff(attempt)
        except KeyboardInterrupt:
            print("\nShutting down...", file=sys.stderr, flush=True)
            break
        except Exception as e:
            print(f"Unexpected error: {e}", file=sys.stderr, flush=True)
            import traceback
            traceback.print_exc(file=sys.stderr)
            attempt += 1
            backoff(attempt)

if __name__ == '__main__':
    ingest()
