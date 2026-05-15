#!/usr/bin/env bash
# PATH: scripts/collect_logs.sh
# WHAT: collects all observability logs into single uploadable tarball
# WHY: user needs to upload logs to LLM for analysis
# VERIFIES WITH: tarball created with all log sources

set -euxo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/observability_logs_${TIMESTAMP}"
TARBALL="/tmp/observability_logs_${TIMESTAMP}.tar.gz"

echo "=== Collecting Observability Logs at $(date) ==="
mkdir -p "$OUTPUT_DIR"/{bash_logs,systemd_logs,database_logs,system_state}

echo "[1/6] Collecting bash script logs..."
if [[ -d /var/log/observability ]]; then
    cp -v /var/log/observability/*.log "$OUTPUT_DIR/bash_logs/" 2>&1 || echo "Some log files may not exist yet"
    ls -lh "$OUTPUT_DIR/bash_logs/"
else
    echo "  /var/log/observability does not exist - no bash logs to collect"
fi

echo "[2/6] Collecting systemd service logs..."
for service in journal-ingester psi-collector websocket-broker; do
    echo "  Collecting $service..."
    journalctl -u ${service}.service -n 1000 --no-pager > "$OUTPUT_DIR/systemd_logs/${service}.log" 2>&1 || echo "    Service may not be running"
done

echo "[3/6] Collecting database events (last 1000)..."
psql "dbname=observability user=observer" -c "
    COPY (
        SELECT time, host, pid, event_type, severity, subsystem, message, raw_payload
        FROM events
        ORDER BY time DESC
        LIMIT 1000
    ) TO STDOUT WITH CSV HEADER
" > "$OUTPUT_DIR/database_logs/events_last_1000.csv" 2>&1 || echo "  Database may not be accessible"

echo "[4/6] Collecting error events only (last 500)..."
psql "dbname=observability user=observer" -c "
    COPY (
        SELECT time, host, event_type, severity, subsystem, message, raw_payload
        FROM events
        WHERE severity IN ('error', 'critical')
        ORDER BY time DESC
        LIMIT 500
    ) TO STDOUT WITH CSV HEADER
" > "$OUTPUT_DIR/database_logs/errors_last_500.csv" 2>&1 || echo "  Database may not be accessible"

echo "[5/6] Collecting system state..."
df -h > "$OUTPUT_DIR/system_state/disk_usage.txt"
free -h > "$OUTPUT_DIR/system_state/memory.txt"
systemctl list-units --type=service --state=failed --no-pager > "$OUTPUT_DIR/system_state/failed_services.txt"
journalctl -p err -n 200 --no-pager > "$OUTPUT_DIR/system_state/system_errors.log"

echo "[6/6] Creating tarball..."
tar -czf "$TARBALL" -C /tmp "observability_logs_${TIMESTAMP}"
ls -lh "$TARBALL"

echo ""
echo "=========================================="
echo "✓ Log collection complete"
echo "=========================================="
echo "Upload this file to Claude:"
echo "  $TARBALL"
echo ""
echo "Or view contents:"
echo "  tar -tzf $TARBALL | head -20"
echo "  tar -xzf $TARBALL -C /tmp && ls -R /tmp/observability_logs_${TIMESTAMP}"
