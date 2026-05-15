#!/usr/bin/env bash
# PATH: scripts/psi_collector.sh
set -euxo pipefail

LOGFILE="/var/log/observability/psi_collector.log"
exec > >(tee -a "$LOGFILE") 2>&1

DB_DSN="${DB_DSN:-dbname=observability user=observer}"
HOST="$(hostname)"

echo "=== PSI Collector starting at $(date) ==="

if [[ ! -d /proc/pressure ]]; then
    echo "ERROR: /proc/pressure not found. Kernel must be >=4.20 with CONFIG_PSI=y"
    exit 1
fi

parse_psi() {
    local file="$1"
    local line_type="$2"
    
    if [[ ! -f "$file" ]]; then
        echo "0.0 0.0 0.0 0"
        return
    fi
    
    echo "  Reading $file ($line_type line):"
    cat "$file"
    
    grep "^${line_type}" "$file" | awk '{
        gsub(/avg10=/, "", $2)
        gsub(/avg60=/, "", $3)
        gsub(/avg300=/, "", $4)
        gsub(/total=/, "", $5)
        print $2, $3, $4, $5
    }'
}

while true; do
    TIMESTAMP="$(date -Iseconds)"
    echo "=== Collection cycle: $TIMESTAMP ==="
    
    read -r cpu_some_10 cpu_some_60 cpu_some_300 cpu_some_total < <(parse_psi /proc/pressure/cpu some)
    read -r mem_some_10 mem_some_60 mem_some_300 mem_some_total < <(parse_psi /proc/pressure/memory some)
    read -r mem_full_10 mem_full_60 mem_full_300 mem_full_total < <(parse_psi /proc/pressure/memory full)
    read -r io_some_10 io_some_60 io_some_300 io_some_total < <(parse_psi /proc/pressure/io some)
    read -r io_full_10 io_full_60 io_full_300 io_full_total < <(parse_psi /proc/pressure/io full)
    
    echo "Parsed values:"
    echo "  CPU some: avg10=$cpu_some_10 avg60=$cpu_some_60 avg300=$cpu_some_300"
    echo "  MEM some: avg10=$mem_some_10 avg60=$mem_some_60 avg300=$mem_some_300"
    echo "  MEM full: avg10=$mem_full_10 avg60=$mem_full_60 avg300=$mem_full_300"
    echo "  IO some:  avg10=$io_some_10 avg60=$io_some_60 avg300=$io_some_300"
    echo "  IO full:  avg10=$io_full_10 avg60=$io_full_60 avg300=$io_full_300"
    
    echo "Inserting into database..."
    psql "$DB_DSN" -c "
        INSERT INTO events (time, host, event_type, subsystem, raw_payload)
        VALUES (
            '$TIMESTAMP',
            '$HOST',
            'psi',
            'kernel',
            '{
                \"cpu_some_avg10\": $cpu_some_10,
                \"cpu_some_avg60\": $cpu_some_60,
                \"cpu_some_avg300\": $cpu_some_300,
                \"mem_some_avg10\": $mem_some_10,
                \"mem_some_avg60\": $mem_some_60,
                \"mem_full_avg10\": $mem_full_10,
                \"mem_full_avg60\": $mem_full_60,
                \"io_some_avg10\": $io_some_10,
                \"io_some_avg60\": $io_some_60,
                \"io_full_avg10\": $io_full_10,
                \"io_full_avg60\": $io_full_60
            }'::jsonb
        );
    "
    echo "Insert complete"
    
    sleep 5
done
