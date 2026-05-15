#!/usr/bin/env bash
# PATH: scripts/screenshot_capture.sh
set -euxo pipefail

LOGFILE="/var/log/observability/screenshot_capture.log"
exec > >(tee -a "$LOGFILE") 2>&1

EVIDENCE_DIR="/var/lib/observability/evidence"
mkdir -p "$EVIDENCE_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SCREENSHOT_FILE="$EVIDENCE_DIR/screenshot_${TIMESTAMP}.png"

echo "=== Screenshot Capture at $(date) ==="
echo "Target file: $SCREENSHOT_FILE"

if command -v grim; then
    echo "Using grim (Wayland)"
    grim "$SCREENSHOT_FILE"
elif command -v scrot; then
    echo "Using scrot (X11)"
    scrot "$SCREENSHOT_FILE"
elif command -v import; then
    echo "Using imagemagick import"
    import -window root "$SCREENSHOT_FILE"
else
    echo "ERROR: No screenshot tool found"
    exit 1
fi

ls -lh "$SCREENSHOT_FILE"

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"

echo "Inserting reference into database..."
psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'screenshot', 'evidence', 'Screenshot captured', '{\"filepath\": \"$SCREENSHOT_FILE\"}'::jsonb);"

echo "Complete"
