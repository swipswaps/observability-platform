#!/usr/bin/env bash
# PATH: scripts/auto_remediate.sh
# WHAT: reads events table and applies fixes for known error patterns
# WHY: self-healing based on logged diagnostics per user's mandate
# VERIFIES WITH: events table updated with remediation attempts

set -euxo pipefail

LOGFILE="/var/log/observability/auto_remediate.log"
exec > >(tee -a "$LOGFILE") 2>&1

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"

echo "=== Auto-Remediation Starting at $(date) ==="

echo "[1/4] Checking for Firefox permission errors..."
PERMISSION_ERRORS=$(psql "$DB_DSN" -t -c "
    SELECT COUNT(*)
    FROM events
    WHERE event_type = 'firefox_permission_errors'
      AND time > NOW() - INTERVAL '1 hour';
")

echo "  Found: $PERMISSION_ERRORS recent permission errors"

if [[ $PERMISSION_ERRORS -gt 0 ]]; then
    echo "  Fixing Firefox directory permissions..."
    
    FIREFOX_DIR="$HOME/.mozilla/firefox"
    if [[ -d "$FIREFOX_DIR" ]]; then
        echo "  Current ownership:"
        ls -ld "$FIREFOX_DIR"
        
        echo "  Fixing ownership recursively..."
        chown -R "$(whoami):$(whoami)" "$FIREFOX_DIR" 2>&1
        
        echo "  Fixing permissions..."
        chmod -R u+rwX "$FIREFOX_DIR" 2>&1
        
        echo "  After fix:"
        ls -ld "$FIREFOX_DIR"
        
        psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'auto_remediation', 'info', 'remediate', 'Fixed Firefox directory permissions');"
    fi
fi

echo "[2/4] Checking for llvmpipe software rendering..."
LLVMPIPE_COUNT=$(psql "$DB_DSN" -t -c "
    SELECT COUNT(*)
    FROM events
    WHERE event_type = 'llvmpipe_detected'
      AND time > NOW() - INTERVAL '1 hour';
")

echo "  Found: $LLVMPIPE_COUNT llvmpipe detections"

if [[ $LLVMPIPE_COUNT -gt 3 ]]; then
    echo "  ALERT: Persistent software rendering detected"
    echo "  Recommended actions:"
    echo "    1. Check: lspci | grep -i vga"
    echo "    2. Verify GPU drivers installed"
    echo "    3. Check: glxinfo | grep 'OpenGL renderer'"
    
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'persistent_llvmpipe', 'warning', 'remediate', 'Software rendering persists - manual GPU driver check needed', '{\"count\": $LLVMPIPE_COUNT}'::jsonb);"
fi

echo "[3/4] Checking for database connection failures..."
DB_ERRORS=$(psql "$DB_DSN" -t -c "
    SELECT COUNT(*)
    FROM events
    WHERE message LIKE '%connection%failed%'
      AND time > NOW() - INTERVAL '1 hour';
")

echo "  Found: $DB_ERRORS connection errors"

if [[ $DB_ERRORS -gt 5 ]]; then
    echo "  Testing database connectivity..."
    systemctl status postgresql --no-pager -l
    
    echo "  Checking pg_hba.conf..."
    sudo grep -v "^#" /var/lib/pgsql/data/pg_hba.conf | grep -v "^$"
    
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'db_connectivity_check', 'info', 'remediate', 'Database connectivity verified during remediation');"
fi

echo "[4/4] Summary - recent events by type:"
psql "$DB_DSN" -c "
    SELECT event_type, COUNT(*) as count
    FROM events
    WHERE time > NOW() - INTERVAL '1 hour'
    GROUP BY event_type
    ORDER BY count DESC
    LIMIT 10;
"

echo "Auto-remediation complete"
