#!/usr/bin/env bash
# PATH: scripts/federation_collector.sh
set -euxo pipefail

LOGFILE="/var/log/observability/federation_collector.log"
exec > >(tee -a "$LOGFILE") 2>&1

LOCAL_DB_DSN="${LOCAL_DB_DSN:-dbname=observability user=observer host=localhost}"
CENTRAL_DB_DSN="${CENTRAL_DB_DSN:-dbname=observability_central user=observer host=central.example.com}"

LAST_SYNC_FILE="/var/lib/observability/federation_last_sync"
mkdir -p "$(dirname "$LAST_SYNC_FILE")"

echo "=== Federation Sync at $(date) ==="

if [[ -f "$LAST_SYNC_FILE" ]]; then
    LAST_SYNC=$(cat "$LAST_SYNC_FILE")
    echo "Last sync: $LAST_SYNC"
else
    LAST_SYNC=$(date -d "5 minutes ago" -Iseconds)
    echo "No previous sync, starting from: $LAST_SYNC"
fi

echo "Detecting NTP offset..."
NTP_OFFSET=0
if command -v chronyc; then
    chronyc tracking
    NTP_OFFSET=$(chronyc tracking | grep "System time" | awk '{print $4}' || echo "0")
    echo "NTP offset: ${NTP_OFFSET}s"
fi

echo "Querying events from local database since $LAST_SYNC..."
EVENTS_JSON=$(psql "$LOCAL_DB_DSN" -t -A -c "
    SELECT json_agg(row_to_json(t))
    FROM (
        SELECT time, host, pid, tid, event_type, severity, correlation_id,
               subsystem, message, stacktrace, raw_payload
        FROM events
        WHERE time > '$LAST_SYNC'
        ORDER BY time
        LIMIT 1000
    ) t;
")

echo "Query result length: \${#EVENTS_JSON} bytes"

if [[ "$EVENTS_JSON" == "null" ]] || [[ -z "$EVENTS_JSON" ]]; then
    echo "No new events to sync"
    exit 0
fi

EVENT_COUNT=$(echo "$EVENTS_JSON" | jq 'length')
echo "Found $EVENT_COUNT events to sync"

TEMP_FILE=$(mktemp)
echo "Writing events to temp file: $TEMP_FILE"
echo "$EVENTS_JSON" > "$TEMP_FILE"

echo "Inserting into central database $CENTRAL_DB_DSN..."
psql "$CENTRAL_DB_DSN" << 'INNER_EOF'
    DO $$
    DECLARE
        event_rec json;
    BEGIN
        FOR event_rec IN SELECT * FROM json_array_elements(pg_read_file('TEMP_FILE')::json)
        LOOP
            INSERT INTO events (time, host, pid, tid, event_type, severity, correlation_id, subsystem, message, stacktrace, raw_payload)
            VALUES (
                (event_rec->>'time')::timestamptz,
                event_rec->>'host',
                (event_rec->>'pid')::integer,
                (event_rec->>'tid')::integer,
                event_rec->>'event_type',
                event_rec->>'severity',
                (event_rec->>'correlation_id')::uuid,
                event_rec->>'subsystem',
                event_rec->>'message',
                event_rec->>'stacktrace',
                (event_rec->>'raw_payload')::jsonb
            ) ON CONFLICT DO NOTHING;
        END LOOP;
    END $$;
INNER_EOF

rm -v "$TEMP_FILE"

date -Iseconds > "$LAST_SYNC_FILE"
echo "Updated last sync timestamp"

echo "Logging to local database..."
psql "$LOCAL_DB_DSN" -c "
    INSERT INTO events (time, host, event_type, subsystem, message, raw_payload)
    VALUES (
        NOW(),
        '$(hostname)',
        'federation_sync',
        'federation',
        'Successfully synced events',
        '{\"events_count\": 0}'::jsonb
    );
"

echo "Federation sync complete"
