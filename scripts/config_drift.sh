#!/usr/bin/env bash
# PATH: scripts/config_drift.sh
set -euxo pipefail

LOGFILE="/var/log/observability/config_drift.log"
exec > >(tee -a "$LOGFILE") 2>&1

SNAPSHOT_DIR="/var/lib/observability/config_snapshots"
mkdir -p "$SNAPSHOT_DIR"

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

echo "=== Config Drift Detection at $(date) ==="

CONFIG_FILES=(
    /etc/fstab
    /etc/sysctl.conf
    /etc/ssh/sshd_config
    ~/.bashrc
    ~/.profile
)

SNAPSHOT_FILE="$SNAPSHOT_DIR/snapshot_${TIMESTAMP}.tar.gz"

echo "Listing previous snapshots..."
LS_OUTPUT=$(ls -t "$SNAPSHOT_DIR"/snapshot_*.tar.gz 2>&1) || echo "(no previous snapshots or ls failed)"
echo "$LS_OUTPUT"

PREV_SNAPSHOT=$(echo "$LS_OUTPUT" | grep -v "No such file" | head -1 || echo "")

if [[ -z "$PREV_SNAPSHOT" && "$LS_OUTPUT" =~ "No such file" ]]; then
    echo "No previous snapshots found - this will be the baseline"
fi

echo "Creating snapshot: $SNAPSHOT_FILE"
TAR_OUTPUT=$(tar -czf "$SNAPSHOT_FILE" "${CONFIG_FILES[@]}" 2>&1)
TAR_EXIT=$?

echo "Tar output:"
echo "$TAR_OUTPUT"

if [[ $TAR_EXIT -ne 0 ]]; then
    echo "Tar failed with exit $TAR_EXIT"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'config_snapshot_error', 'error', 'config', 'Failed to create config snapshot', '{\"exit_code\": $TAR_EXIT, \"output\": $(echo "$TAR_OUTPUT" | jq -Rs .)}'::jsonb);"
fi

ls -lh "$SNAPSHOT_FILE"

if [[ -n "$PREV_SNAPSHOT" ]]; then
    echo "Comparing with previous: $PREV_SNAPSHOT"
    
    TEMP_DIR=$(mktemp -d)
    mkdir -p "$TEMP_DIR"/{prev,curr}
    
    echo "Extracting previous snapshot..."
    tar -xzf "$PREV_SNAPSHOT" -C "$TEMP_DIR/prev" 2>&1
    
    echo "Extracting current snapshot..."
    tar -xzf "$SNAPSHOT_FILE" -C "$TEMP_DIR/curr" 2>&1
    
    echo "Running diff..."
    DIFF_OUTPUT=$(diff -r "$TEMP_DIR/prev" "$TEMP_DIR/curr" 2>&1) || echo "(diff completed - exit code indicates differences found)"
    
    if [[ -n "$DIFF_OUTPUT" ]]; then
        echo "DRIFT DETECTED:"
        echo "$DIFF_OUTPUT"
        
        DIFF_LINE_COUNT=$(echo "$DIFF_OUTPUT" | wc -l)
        
        echo "Inserting drift event into database..."
        psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message, raw_payload) VALUES (NOW(), '$HOST', 'config_drift', 'warning', 'config', 'Configuration drift detected', $(echo "{\"diff_lines\": $DIFF_LINE_COUNT, \"diff_output\": $(echo "$DIFF_OUTPUT" | head -100 | jq -Rs .)}" | jq -c .)::jsonb);"
    else
        echo "No drift detected"
    fi
    
    rm -rf "$TEMP_DIR"
else
    echo "No previous snapshot - this is the baseline"
    psql "$DB_DSN" -c "INSERT INTO events (time, host, event_type, severity, subsystem, message) VALUES (NOW(), '$HOST', 'config_baseline', 'info', 'config', 'Baseline snapshot created');"
fi

echo "Config drift check complete"
