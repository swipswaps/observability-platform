#!/usr/bin/env bash
# PATH: scripts/validate_observability.sh
set -euxo pipefail

LOGFILE="/var/log/observability/validate_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"
FAILED_TESTS=0

echo "=========================================="
echo "OBSERVABILITY PLATFORM VALIDATION"
echo "Starting: $(date)"
echo "Logging to: $LOGFILE"
echo "=========================================="

test_passed() { echo "  ✓ $1"; }
test_failed() { echo "  ✗ $1"; ((FAILED_TESTS++)) || true; }

echo "[1/10] Testing database connectivity..."
psql "$DB_DSN" -c "SELECT 1;"
[[ $? -eq 0 ]] && test_passed "Database reachable" || test_failed "Cannot connect"

echo "[2/10] Checking events table..."
psql "$DB_DSN" -c "SELECT COUNT(*) FROM events LIMIT 1;"
[[ $? -eq 0 ]] && test_passed "Events table exists" || test_failed "Events table not found"

echo "[3/10] Checking TimescaleDB..."
RESULT=$(psql "$DB_DSN" -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname='timescaledb';")
echo "  Result: $RESULT"
[[ "$RESULT" =~ "1" ]] && test_passed "TimescaleDB loaded" || test_failed "TimescaleDB not found"

echo "[4/10] Checking journal-ingester..."
systemctl status journal-ingester.service --no-pager -l || true
systemctl is-active --quiet journal-ingester.service && test_passed "journal-ingester running" || test_failed "journal-ingester not running"

echo "[5/10] Checking psi-collector..."
systemctl status psi-collector.timer --no-pager -l || true
systemctl is-active --quiet psi-collector.timer && test_passed "psi-collector active" || test_failed "psi-collector not active"

echo "[6/10] Checking recent events..."
RECENT_EVENTS=$(psql "$DB_DSN" -t -c "SELECT COUNT(*) FROM events WHERE time > NOW() - INTERVAL '10 minutes';")
echo "  Found: $RECENT_EVENTS"
[[ $RECENT_EVENTS -gt 0 ]] && test_passed "$RECENT_EVENTS recent events" || test_failed "No recent events"

echo "[7/10] Checking dead letter queue..."
DEAD_LETTER_SIZE=0
if [[ -f /var/lib/observability/dead_letter.jsonl ]]; then
    DEAD_LETTER_SIZE=$(wc -l < /var/lib/observability/dead_letter.jsonl)
    echo "  Size: $DEAD_LETTER_SIZE events"
    cat /var/lib/observability/dead_letter.jsonl || true
fi
[[ $DEAD_LETTER_SIZE -lt 100 ]] && test_passed "Queue size OK ($DEAD_LETTER_SIZE)" || test_failed "Queue large ($DEAD_LETTER_SIZE)"

echo "[8/10] Testing event insertion..."
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'validation_test', 'info', 'validate', 'Test event');"
[[ $? -eq 0 ]] && test_passed "Insert successful" || test_failed "Insert failed"

echo "[9/10] Testing query performance..."
START=$(date +%s)
psql "$DB_DSN" -c "SELECT COUNT(*) FROM events WHERE time > NOW() - INTERVAL '1 hour';"
END=$(date +%s)
QUERY_TIME=$((END - START))
echo "  Took: ${QUERY_TIME}s"
[[ $QUERY_TIME -lt 5 ]] && test_passed "Performance OK (${QUERY_TIME}s)" || test_failed "Slow (${QUERY_TIME}s)"

echo "[10/10] Checking disk space..."
df -h /var/lib/observability
DISK_USAGE=$(df /var/lib/observability | tail -1 | awk '{print $5}' | sed 's/%//')
[[ $DISK_USAGE -lt 90 ]] && test_passed "Disk OK (${DISK_USAGE}%)" || test_failed "Disk critical (${DISK_USAGE}%)"

psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'validation_result', CASE WHEN $FAILED_TESTS = 0 THEN 'info' ELSE 'error' END, 'validate', 'Validation completed', '{\"failed_tests\": $FAILED_TESTS}'::jsonb);"

echo "=========================================="
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo "ALL TESTS PASSED ✓"
    echo "Log: $LOGFILE"
    exit 0
else
    echo "$FAILED_TESTS TEST(S) FAILED ✗"
    echo "Log: $LOGFILE"
    exit 1
fi
