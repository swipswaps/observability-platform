#!/usr/bin/env python3
# PATH: scripts/dead_letter_replay.py
import json
import psycopg2
import os
import sys
from pathlib import Path
from datetime import datetime

DEAD_LETTER_FILE = Path('/var/lib/observability/dead_letter.jsonl')
PROCESSED_FILE = Path('/var/lib/observability/dead_letter_processed.jsonl')
DB_DSN = os.getenv('DB_DSN', 'dbname=observability user=observer')

print(f"=== Dead Letter Replay Starting ===", file=sys.stderr, flush=True)
print(f"Dead letter file: {DEAD_LETTER_FILE}", file=sys.stderr, flush=True)

def replay_events():
    if not DEAD_LETTER_FILE.exists():
        print("No dead-letter file found", file=sys.stderr, flush=True)
        return
    
    file_size = DEAD_LETTER_FILE.stat().st_size
    print(f"Dead-letter file size: {file_size} bytes", file=sys.stderr, flush=True)
    
    if file_size == 0:
        print("Dead-letter file is empty", file=sys.stderr, flush=True)
        return
    
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()
    
    success_count = 0
    fail_count = 0
    failed_events = []
    
    with DEAD_LETTER_FILE.open('r') as f:
        for line_num, line in enumerate(f, 1):
            try:
                event = json.loads(line.strip())
                print(f"Replaying event {line_num}: {event.get('event_type', 'unknown')}", file=sys.stderr, flush=True)
                
                cur.execute("""
                    INSERT INTO events (time, host, pid, event_type, severity, subsystem, message, raw_payload)
                    VALUES (%(time)s, %(host)s, %(pid)s, %(event_type)s, %(severity)s, %(subsystem)s, %(message)s, %(raw_payload)s)
                """, event)
                conn.commit()
                success_count += 1
                
            except (json.JSONDecodeError, psycopg2.Error) as e:
                print(f"Failed line {line_num}: {e}", file=sys.stderr, flush=True)
                fail_count += 1
                failed_events.append(line)
                conn.rollback()
    
    if failed_events:
        with DEAD_LETTER_FILE.open('w') as f:
            f.writelines(failed_events)
        print(f"Retained {len(failed_events)} failed events", file=sys.stderr, flush=True)
    else:
        DEAD_LETTER_FILE.unlink()
        print("All events replayed - file cleared", file=sys.stderr, flush=True)
    
    if success_count > 0:
        with PROCESSED_FILE.open('a') as f:
            f.write(f"# Replay: {datetime.now().isoformat()}\n")
            f.write(f"# Success: {success_count}, Failed: {fail_count}\n\n")
    
    cur.execute("""
        INSERT INTO events (time, host, event_type, subsystem, message, raw_payload)
        VALUES (NOW(), %s, 'dead_letter_replay', 'recovery', 'Replay completed', %s::jsonb);
    """, (os.uname().nodename, json.dumps({'success_count': success_count, 'fail_count': fail_count, 'file_size_bytes': file_size})))
    conn.commit()
    
    print(f"Replay complete: {success_count} succeeded, {fail_count} failed", file=sys.stderr, flush=True)

if __name__ == '__main__':
    try:
        replay_events()
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr, flush=True)
        import traceback
        traceback.print_exc(file=sys.stderr)
        exit(1)
