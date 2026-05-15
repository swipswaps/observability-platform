#!/usr/bin/env python3
# PATH: scripts/adaptive_sampler.py
import psycopg2
import time
import os
import sys

DB_DSN = os.getenv('DB_DSN', 'dbname=observability user=observer')
QUEUE_THRESHOLD = 0.80
CHECK_INTERVAL = 10

print(f"=== Adaptive Sampler Starting ===", file=sys.stderr, flush=True)
print(f"DB_DSN: {DB_DSN}", file=sys.stderr, flush=True)
print(f"Threshold: {QUEUE_THRESHOLD}", file=sys.stderr, flush=True)

def get_queue_depth(cursor):
    cursor.execute("""
        SELECT 
            COUNT(*) as pending_events,
            EXTRACT(EPOCH FROM (MAX(time) - MIN(time))) as time_span_seconds
        FROM events
        WHERE time > NOW() - INTERVAL '1 minute';
    """)
    result = cursor.fetchone()
    print(f"Query result: {result}", file=sys.stderr, flush=True)
    
    if not result or result[1] == 0:
        return 0.0
    
    pending, time_span = result
    events_per_second = pending / time_span if time_span > 0 else 0
    
    PROCESSING_CAPACITY = 1000
    queue_depth = min(1.0, events_per_second / PROCESSING_CAPACITY)
    
    return queue_depth

def calculate_sample_rate(queue_depth):
    if queue_depth < QUEUE_THRESHOLD:
        return 1.0
    
    sample_rate = 1.0 - 0.9 * ((queue_depth - QUEUE_THRESHOLD) / (1.0 - QUEUE_THRESHOLD))
    return max(0.1, sample_rate)

def apply_sampling_policy(cursor, sample_rate):
    print(f"Applying sample rate: {sample_rate}", file=sys.stderr, flush=True)
    
    if sample_rate >= 1.0:
        cursor.execute("DROP TABLE IF EXISTS sampling_policy;")
        return
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS sampling_policy (
            active BOOLEAN DEFAULT TRUE,
            sample_rate FLOAT NOT NULL,
            updated_at TIMESTAMPTZ DEFAULT NOW()
        );
        TRUNCATE sampling_policy;
        INSERT INTO sampling_policy (sample_rate) VALUES (%s);
    """, (sample_rate,))

def monitor_and_adjust():
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()
    
    print("Adaptive sampler loop started", file=sys.stderr, flush=True)
    
    while True:
        try:
            queue_depth = get_queue_depth(cur)
            sample_rate = calculate_sample_rate(queue_depth)
            
            apply_sampling_policy(cur, sample_rate)
            conn.commit()
            
            if sample_rate < 1.0:
                print(f"Queue depth: {queue_depth:.2%}, Sampling: {sample_rate:.2%}", file=sys.stderr, flush=True)
                cur.execute("""
                    INSERT INTO events (time, host, event_type, subsystem, message, raw_payload)
                    VALUES (NOW(), %s, 'adaptive_sampling', 'sampler', 'Load shedding active', %s::jsonb);
                """, (os.uname().nodename, f'{{"queue_depth": {queue_depth}, "sample_rate": {sample_rate}}}'))
                conn.commit()
            
            time.sleep(CHECK_INTERVAL)
            
        except KeyboardInterrupt:
            print("\nShutting down...", file=sys.stderr, flush=True)
            break
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr, flush=True)
            import traceback
            traceback.print_exc(file=sys.stderr)
            time.sleep(CHECK_INTERVAL)
            conn.rollback()

if __name__ == '__main__':
    monitor_and_adjust()
