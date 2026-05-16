#!/usr/bin/env python3
# PATH: scripts/journal_ingester.py
# ============================================================
# Fixes vs previous version:
#   - raw_payload now wrapped in Json() for jsonb column (was passing raw dict)
#   - journalctl stderr piped and logged so permission errors are visible
#   - journalctl exit detected explicitly: logs returncode and stderr tail
#   - attempt NOT reset to 0 until first successful line read (not just proc start)
#   - DB_DSN falls back to host=127.0.0.1 (avoids Unix socket peer auth issues)
#   - severity stored as text label, not raw integer string
# ============================================================
import json
import subprocess
import psycopg2
import psycopg2.extras
import time
import os
import sys
from pathlib import Path
from datetime import datetime

CURSOR_FILE    = Path('/var/lib/observability/journal_cursor')
DEAD_LETTER_FILE = Path('/var/lib/observability/dead_letter.jsonl')

# Use TCP to 127.0.0.1 so md5 auth applies (avoids Unix socket peer auth edge cases)
DB_DSN = os.getenv(
    'DB_DSN',
    'dbname=observability user=observer password=observer host=127.0.0.1'
)

PRIORITY_MAP = {
    '0': 'emerg', '1': 'alert', '2': 'crit',   '3': 'err',
    '4': 'warning', '5': 'notice', '6': 'info', '7': 'debug'
}

print("=== Journal Ingester Starting ===", file=sys.stderr, flush=True)
print(f"DB_DSN: {DB_DSN.replace('password=observer', 'password=***')}", file=sys.stderr, flush=True)


def backoff(attempt):
    wait = min(60, 2 ** attempt)
    print(f"Backing off {wait}s (attempt {attempt})", file=sys.stderr, flush=True)
    time.sleep(wait)


def get_cursor():
    if CURSOR_FILE.exists():
        cursor = CURSOR_FILE.read_text().strip()
        print(f"Resuming from cursor: {cursor[:50]}...", file=sys.stderr, flush=True)
        return cursor
    return None


def save_cursor(cursor):
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(cursor)


def append_dead_letter(entry):
    DEAD_LETTER_FILE.parent.mkdir(parents=True, exist_ok=True)
    with DEAD_LETTER_FILE.open('a') as f:
        f.write(json.dumps(entry, default=str) + '\n')
    print("Wrote to dead letter", file=sys.stderr, flush=True)


def parse_journal_entry(line):
    try:
        entry = json.loads(line)
        ts_usec = int(entry.get('__REALTIME_TIMESTAMP', 0))
        ts = datetime.fromtimestamp(ts_usec / 1_000_000.0) if ts_usec else datetime.utcnow()
        severity = PRIORITY_MAP.get(str(entry.get('PRIORITY', '6')), 'info')
        return {
            'time':        ts,
            'host':        os.uname().nodename,
            'pid':         entry.get('_PID'),
            'event_type':  'journal',
            'severity':    severity,
            'subsystem':   entry.get('_SYSTEMD_UNIT', 'unknown'),
            'message':     entry.get('MESSAGE', ''),
            # psycopg2.extras.Json serializes the dict correctly for jsonb columns
            'raw_payload': psycopg2.extras.Json(entry),
            '__cursor':    entry.get('__CURSOR'),
        }
    except (json.JSONDecodeError, ValueError) as e:
        print(f"Parse error: {e}", file=sys.stderr, flush=True)
        return None


def ingest():
    attempt = 0
    while True:
        conn = None
        proc = None
        try:
            print(f"Connecting to database (attempt {attempt})...", file=sys.stderr, flush=True)
            conn = psycopg2.connect(DB_DSN)
            cur  = conn.cursor()

            cmd = [
                'journalctl', '-f', '-o', 'json',
                '--output-fields=__REALTIME_TIMESTAMP,MESSAGE,PRIORITY,_PID,_SYSTEMD_UNIT,__CURSOR'
            ]
            cursor = get_cursor()
            if cursor:
                cmd.extend(['--after-cursor', cursor])
            else:
                print("Starting from beginning", file=sys.stderr, flush=True)

            print(f"Starting journalctl: {' '.join(cmd)}", file=sys.stderr, flush=True)

            # Pipe stderr so permission/access errors surface in the service log
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1          # line-buffered
            )

            lines_read = 0
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue

                event = parse_journal_entry(line)
                if not event:
                    continue

                # Reset backoff only after a real line is successfully parsed
                if lines_read == 0:
                    print("Connected - streaming journal...", file=sys.stderr, flush=True)
                    attempt = 0
                lines_read += 1

                try:
                    cur.execute("""
                        INSERT INTO events
                            (time, host, pid, event_type, severity, subsystem, message, raw_payload)
                        VALUES
                            (%(time)s, %(host)s, %(pid)s, %(event_type)s,
                             %(severity)s, %(subsystem)s, %(message)s, %(raw_payload)s)
                    """, event)
                    conn.commit()

                    if event['__cursor']:
                        save_cursor(event['__cursor'])

                except psycopg2.Error as e:
                    print(f"DB insert error: {e}", file=sys.stderr, flush=True)
                    append_dead_letter({
                        k: v for k, v in event.items()
                        if k != 'raw_payload'   # Json() not JSON-serialisable directly
                    })
                    conn.rollback()

            # journalctl exited — log why before backing off
            proc.wait()
            stderr_tail = proc.stderr.read(2000).strip()
            print(
                f"journalctl exited (rc={proc.returncode}). "
                f"stderr: {stderr_tail or '(none)'}",
                file=sys.stderr, flush=True
            )
            # Treat unexpected journalctl exit as a retriable error
            raise RuntimeError(f"journalctl exited rc={proc.returncode}")

        except (psycopg2.OperationalError, ConnectionError) as e:
            print(f"DB connection error: {e}", file=sys.stderr, flush=True)
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

        finally:
            if proc and proc.poll() is None:
                proc.terminate()
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass


if __name__ == '__main__':
    ingest()