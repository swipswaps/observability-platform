#!/usr/bin/env bash
# PATH: scripts/failure_injection.sh
set -euxo pipefail

LOGFILE="/var/log/observability/failure_injection.log"
exec > >(tee -a "$LOGFILE") 2>&1

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"

echo "=========================================="
echo "FAILURE INJECTION TEST SUITE"
echo "=========================================="
echo "WARNING: This will stress your system."
echo "Press Ctrl+C to cancel, or wait 5 seconds..."
sleep 5

echo "[1/4] CPU stress test (5 seconds)..."
stress-ng --cpu 4 --timeout 5s --metrics-brief 2>&1 || echo "stress-ng not installed"
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, subsystem, message) VALUES (NOW(), '$HOST', 'failure_injection', 'test', 'CPU stress test');"

echo "[2/4] Memory pressure test (5 seconds)..."
stress-ng --vm 2 --vm-bytes 75% --timeout 5s --metrics-brief 2>&1 || echo "stress-ng not installed"
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, subsystem, message) VALUES (NOW(), '$HOST', 'failure_injection', 'test', 'Memory pressure test');"

echo "[3/4] Disk I/O test (5 seconds)..."
stress-ng --hdd 2 --timeout 5s --metrics-brief 2>&1 || echo "stress-ng not installed"
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, subsystem, message) VALUES (NOW(), '$HOST', 'failure_injection', 'test', 'Disk I/O test');"

echo "[4/4] Network packet loss simulation..."
echo "Simulating packet loss requires root - skipping for safety"
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, subsystem, message) VALUES (NOW(), '$HOST', 'failure_injection', 'test', 'Network test skipped');"

echo "=========================================="
echo "Failure injection tests complete"
echo "Check events table:"
echo "  psql $DB_DSN -c \"SELECT time, event_type, subsystem, message FROM events WHERE subsystem='test' ORDER BY time DESC LIMIT 10;\""
