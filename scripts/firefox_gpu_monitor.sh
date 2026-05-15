#!/usr/bin/env bash
# PATH: scripts/firefox_gpu_monitor.sh
set -euxo pipefail

LOGFILE="/var/log/observability/firefox_gpu_monitor.log"
exec > >(tee -a "$LOGFILE") 2>&1

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"

echo "=== Firefox GPU Monitor at $(date) ==="

FIREFOX_PIDS=$(pgrep -u "$(whoami)" firefox | head -1 || echo "")

if [[ -z "$FIREFOX_PIDS" ]]; then
    echo "No Firefox process found for user $(whoami)"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'firefox_not_running', 'info', 'firefox', 'No Firefox process found');"
    exit 0
fi

echo "Found Firefox PID: $FIREFOX_PIDS"

GPU_ACTIVE="unknown"
COMPOSITING="unknown"
WEBRENDER="unknown"

echo "Searching for Firefox profile..."
FIND_OUTPUT=$(find ~/.mozilla/firefox -name "*.default*" -type d 2>&1) || true
FIND_EXIT=$?

echo "Find output:"
echo "$FIND_OUTPUT"

if [[ $FIND_EXIT -ne 0 ]]; then
    echo "Find command failed with exit $FIND_EXIT"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'firefox_profile_search_error', 'warning', 'firefox', 'Profile search failed', '{\"exit_code\": $FIND_EXIT, \"output\": $(echo "$FIND_OUTPUT" | jq -Rs .)}'::jsonb);"
fi

FIREFOX_PROFILE=$(echo "$FIND_OUTPUT" | grep -v "Permission denied" | head -1 || echo "")

if [[ -z "$FIREFOX_PROFILE" ]]; then
    echo "No Firefox profile found"
    
    PERMISSION_ERRORS=$(echo "$FIND_OUTPUT" | grep -c "Permission denied" || echo "0")
    if [[ $PERMISSION_ERRORS -gt 0 ]]; then
        echo "Detected $PERMISSION_ERRORS permission denied errors - logging to database for remediation"
        psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'firefox_permission_errors', 'error', 'firefox', 'Permission denied accessing Firefox directories', '{\"error_count\": $PERMISSION_ERRORS, \"user\": \"$(whoami)\", \"errors\": $(echo "$FIND_OUTPUT" | grep "Permission denied" | jq -Rs .)}'::jsonb);"
    fi
    
    exit 0
fi

echo "Firefox profile: $FIREFOX_PROFILE"

echo "Checking for llvmpipe in .xsession-errors..."
if [[ -f ~/.xsession-errors ]]; then
    echo "Recent llvmpipe references:"
    LLVMPIPE_OUTPUT=$(grep -i "llvmpipe" ~/.xsession-errors 2>&1 | tail -5) || echo "(grep found none or failed)"
    echo "$LLVMPIPE_OUTPUT"
    
    if echo "$LLVMPIPE_OUTPUT" | grep -qi "llvmpipe"; then
        GPU_ACTIVE="llvmpipe_fallback"
        psql "$DB_DSN" -c "INSERT INTO events (time, host, pid, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', $FIREFOX_PIDS, 'llvmpipe_detected', 'warning', 'firefox', 'Firefox using software rendering');"
    else
        GPU_ACTIVE="hardware"
    fi
else
    echo ".xsession-errors not found"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'xsession_errors_missing', 'info', 'firefox', '.xsession-errors file not found');"
fi

echo "Checking WebRender in prefs.js..."
if [[ -f "$FIREFOX_PROFILE/prefs.js" ]]; then
    WEBRENDER_PREFS=$(grep "gfx.webrender" "$FIREFOX_PROFILE/prefs.js" 2>&1) || echo "(no webrender prefs or grep failed)"
    echo "$WEBRENDER_PREFS"
    
    if echo "$WEBRENDER_PREFS" | grep -q "gfx.webrender.all.*true"; then
        WEBRENDER="enabled"
    else
        WEBRENDER="disabled"
    fi
else
    echo "prefs.js not found at $FIREFOX_PROFILE/prefs.js"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'firefox_prefs_missing', 'warning', 'firefox', 'prefs.js not found', '{\"expected_path\": \"$FIREFOX_PROFILE/prefs.js\"}'::jsonb);"
fi

TIMESTAMP="$(date -Iseconds)"

echo "GPU Status: GPU=$GPU_ACTIVE, WebRender=$WEBRENDER"
echo "Inserting into database..."

psql "$DB_DSN" -c "
    INSERT INTO events (time, host, pid, event_type, subsystem, raw_payload)
    VALUES (
        '$TIMESTAMP',
        '$HOST',
        $FIREFOX_PIDS,
        'gpu_diagnostic',
        'firefox',
        '{
            \"gpu_active\": \"$GPU_ACTIVE\",
            \"compositing\": \"$COMPOSITING\",
            \"webrender\": \"$WEBRENDER\",
            \"profile_path\": \"$FIREFOX_PROFILE\"
        }'::jsonb
    );
"

echo "Insert complete"
