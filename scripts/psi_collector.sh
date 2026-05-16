#!/usr/bin/env bash
# PATH: scripts/psi_collector.sh
# ============================================================
# Fixes vs previous version:
#   - Removed -x from set flags: trace output flooded journal with
#     hundreds of lines per run, overwhelming journal-ingester backlog
#   - DB_DSN now includes host=127.0.0.1 and password= so TCP md5
#     auth works (Unix socket with no password caused fe_sendauth failure)
#   - Removed internal sleep loop: systemd timer handles scheduling,
#     running as a oneshot avoids leaked processes on timer overlap
#   - Removed verbose cat/echo of /proc/pressure files: single
#     summary log line per collection cycle instead
#   - PGPASSWORD exported so psql never prompts interactively
#   - Raw payload uses proper shell variable quoting
# ============================================================
set -euo pipefail

LOGFILE="/var/log/observability/psi_collector.log"
exec > >(tee -a "$LOGFILE") 2>&1

# TCP connection with explicit password — Unix socket md5 requires
# password in connection string, not just username
DB_DSN="${DB_DSN:-dbname=observability user=observer password=observer host=127.0.0.1}"
export PGPASSWORD="${PGPASSWORD:-observer}"

HOST="$(hostname)"
TIMESTAMP="$(date -Iseconds)"

if [[ ! -d /proc/pressure ]]; then
    echo "ERROR: /proc/pressure not found. Kernel must be >=4.20 with CONFIG_PSI=y"
    exit 1
fi

# Parse a single avg10/avg60/avg300/total line from a PSI file
# Returns space-separated values, or "0.0 0.0 0.0 0" if file missing
parse_psi() {
    local file="$1"
    local line_type="$2"

    if [[ ! -f "$file" ]]; then
        echo "0.0 0.0 0.0 0"
        return
    fi

    grep "^${line_type}" "$file" | awk '{
        gsub(/avg10=/, "", $2)
        gsub(/avg60=/, "", $3)
        gsub(/avg300=/, "", $4)
        gsub(/total=/, "", $5)
        print $2, $3, $4, $5
    }'
}

read -r cpu_some_10 cpu_some_60 cpu_some_300 cpu_some_total \
    < <(parse_psi /proc/pressure/cpu some)

read -r mem_some_10 mem_some_60 mem_some_300 mem_some_total \
    < <(parse_psi /proc/pressure/memory some)

read -r mem_full_10 mem_full_60 mem_full_300 mem_full_total \
    < <(parse_psi /proc/pressure/memory full)

read -r io_some_10 io_some_60 io_some_300 io_some_total \
    < <(parse_psi /proc/pressure/io some)

read -r io_full_10 io_full_60 io_full_300 io_full_total \
    < <(parse_psi /proc/pressure/io full)

echo "PSI cycle $TIMESTAMP cpu=${cpu_some_10} mem=${mem_some_10}/${mem_full_10} io=${io_some_10}/${io_full_10}"

psql "$DB_DSN" -c "
    INSERT INTO events (time, host, event_type, subsystem, raw_payload)
    VALUES (
        '$TIMESTAMP',
        '$HOST',
        'psi',
        'kernel',
        '{
            \"cpu_some_avg10\":  $cpu_some_10,
            \"cpu_some_avg60\":  $cpu_some_60,
            \"cpu_some_avg300\": $cpu_some_300,
            \"mem_some_avg10\":  $mem_some_10,
            \"mem_some_avg60\":  $mem_some_60,
            \"mem_full_avg10\":  $mem_full_10,
            \"mem_full_avg60\":  $mem_full_60,
            \"io_some_avg10\":   $io_some_10,
            \"io_some_avg60\":   $io_some_60,
            \"io_full_avg10\":   $io_full_10,
            \"io_full_avg60\":   $io_full_60
        }'::jsonb
    );
" && echo "✓ PSI inserted" || echo "✗ PSI insert failed"