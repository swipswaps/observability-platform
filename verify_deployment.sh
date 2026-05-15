#!/usr/bin/env bash
# PATH: verify_deployment.sh
set -euo pipefail

echo "=========================================="
echo "DEPLOYMENT VERIFICATION"
echo "=========================================="
echo ""

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $desc"
        ((PASS++))
    else
        echo "  ✗ $desc"
        ((FAIL++))
    fi
}

echo "[1/10] Directories..."
check "/var/log/observability exists" "[[ -d /var/log/observability ]]"
check "/var/lib/observability exists" "[[ -d /var/lib/observability ]]"

echo ""
echo "[2/10] Scripts..."
check "collect_logs.sh installed" "[[ -x /usr/local/bin/collect_logs.sh ]]"
check "auto_remediate.sh installed" "[[ -x /usr/local/bin/auto_remediate.sh ]]"
check "journal_ingester.py installed" "[[ -x /usr/local/bin/journal_ingester.py ]]"

echo ""
echo "[3/10] Systemd units..."
check "journal-ingester.service installed" "[[ -f /etc/systemd/system/journal-ingester.service ]]"
check "psi-collector.timer installed" "[[ -f /etc/systemd/system/psi-collector.timer ]]"

echo ""
echo "[4/10] Services running..."
check "journal-ingester active" "systemctl is-active journal-ingester"
check "psi-collector.timer active" "systemctl is-active psi-collector.timer"

echo ""
echo "[5/10] Database..."
check "PostgreSQL running" "systemctl is-active postgresql"
check "observer can connect" "psql 'dbname=observability user=observer password=observer host=localhost' -c 'SELECT 1' >/dev/null 2>&1"

echo ""
echo "[6/10] Logs appearing..."
sleep 5
LOG_COUNT=$(ls -1 /var/log/observability/*.log 2>/dev/null | wc -l)
if [[ $LOG_COUNT -gt 0 ]]; then
    echo "  ✓ Found $LOG_COUNT log files"
    ls -lh /var/log/observability/
    ((PASS++))
else
    echo "  ✗ No log files yet (services may need more time)"
    ((FAIL++))
fi

echo ""
echo "[7/10] Journal entries..."
JOURNAL_LINES=$(journalctl -u journal-ingester -n 10 --no-pager 2>/dev/null | wc -l)
if [[ $JOURNAL_LINES -gt 1 ]]; then
    echo "  ✓ journal-ingester has $JOURNAL_LINES log lines"
    ((PASS++))
else
    echo "  ✗ journal-ingester has no logs"
    ((FAIL++))
fi

echo ""
echo "[8/10] Database events..."
EVENT_COUNT=$(psql "dbname=observability user=observer password=observer host=localhost" -t -c "SELECT COUNT(*) FROM events;" 2>/dev/null || echo "0")
if [[ $EVENT_COUNT -gt 0 ]]; then
    echo "  ✓ Database has $EVENT_COUNT events"
    ((PASS++))
else
    echo "  ✗ No events in database yet"
    ((FAIL++))
fi

echo ""
echo "[9/10] Log collection works..."
if bash /usr/local/bin/collect_logs.sh 2>&1 | grep -q "Log collection complete"; then
    echo "  ✓ Log collection completed"
    ((PASS++))
else
    echo "  ✗ Log collection failed"
    ((FAIL++))
fi

echo ""
echo "[10/10] Recent events sample..."
psql "dbname=observability user=observer password=observer host=localhost" -c "SELECT time, event_type, subsystem, message FROM events ORDER BY time DESC LIMIT 5;" 2>/dev/null || echo "  (no events yet)"

echo ""
echo "=========================================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=========================================="

if [[ $FAIL -eq 0 ]]; then
    echo "✓✓✓ ALL CHECKS PASSED ✓✓✓"
    exit 0
else
    echo "Some checks failed - review output above"
    exit 1
fi
