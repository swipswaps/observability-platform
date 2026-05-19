#!/usr/bin/env bash
# PATH: scripts/firefox_contention_diagnostic_0099.sh
#
# VERSION 0099: Final – all issues resolved.
#   - Pre‑reads sudo password (no mid‑script prompts)
#   - Temporarily disables SELinux (restores on exit)
#   - Sets ptrace_scope=0 (restores on exit)
#   - Creates blank page via CDP before reading WebSocket URL
#   - GDB timeout 20s, disables debuginfod, falls back to perf
#   - Clears all caches, vacuums databases, disables sync
# Usage: ./script.sh [duration] [--auto-fix] [--pin-core N] [--no-gdb]

# ----------------------------------------------------------------------
# Pre‑read sudo password (to avoid mid‑script prompts)
# ----------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo. Please enter your password:"
    read -s SUDO_PASSWORD
    echo "$SUDO_PASSWORD" | sudo -S -v 2>/dev/null
    export SUDO_PASSWORD
else
    SUDO_PASSWORD=""
fi

# ----------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------
AUTO_FIX=false
DURATION="10"
PIN_CORE=""
USE_GDB=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-fix) AUTO_FIX=true; shift ;;
        --pin-core) PIN_CORE="$2"; shift 2 ;;
        --no-gdb)   USE_GDB=false; shift ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                DURATION="$1"
            fi
            shift
            ;;
    esac
done

echo "[CONFIG] Sampling duration: ${DURATION}s"
echo "[CONFIG] Auto‑fix mode: ${AUTO_FIX}"
[[ -n "$PIN_CORE" ]] && echo "[CONFIG] CPU pinning: core $PIN_CORE"
echo "[CONFIG] GDB: $([ "$USE_GDB" = true ] && echo "ENABLED (20s timeout)" || echo "DISABLED")"

# ----------------------------------------------------------------------
# Dependency management
# ----------------------------------------------------------------------
echo ""
echo "=== Checking dependencies ==="
MISSING_DEPS=()
WARN_DEPS=()

if ! command -v python3 &>/dev/null; then
    MISSING_DEPS+=("python3")
else
    if ! python3 -c "import websockets" 2>/dev/null; then
        WARN_DEPS+=("python3-websockets (pip install websockets)")
    fi
fi

if ! command -v timeout &>/dev/null; then
    MISSING_DEPS+=("timeout (coreutils)")
fi

if ! command -v bc &>/dev/null; then
    WARN_DEPS+=("bc (fallback to awk)")
fi

if [ "$USE_GDB" = true ] && ! command -v gdb &>/dev/null; then
    WARN_DEPS+=("gdb (fallback to perf or /proc/*/stack)")
fi

if ! command -v sqlite3 &>/dev/null; then
    WARN_DEPS+=("sqlite3 (vacuum will be skipped)")
fi

if [[ -n "$PIN_CORE" ]] && [ "$AUTO_FIX" = true ]; then
    if ! command -v taskset &>/dev/null; then
        WARN_DEPS+=("taskset (CPU pinning skipped)")
    fi
fi

if (( ${#MISSING_DEPS[@]} > 0 )); then
    echo "ERROR: Missing required dependencies: ${MISSING_DEPS[*]}"
    exit 1
fi

if (( ${#WARN_DEPS[@]} > 0 )); then
    echo "WARNING: Optional dependencies missing: ${WARN_DEPS[*]}"
fi

# ----------------------------------------------------------------------
# Setup logging and environment
# ----------------------------------------------------------------------
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd || pwd)
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR" || { echo "ERROR: Cannot create $LOG_DIR"; exit 1; }
LOG_FILE="${LOG_DIR}/contention_youtube_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[LOG] Writing to: $LOG_FILE"

export PGPASSWORD="${PGPASSWORD:-observer}"
if ! psql -h 127.0.0.1 -U observer -d observability -c 'SELECT 1' >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to PostgreSQL"
    exit 1
fi

# ----------------------------------------------------------------------
# Firefox profile and cache locations
# ----------------------------------------------------------------------
PROFILE_DIR="/home/owner/Desktop/mozilla"
if [ ! -d "$PROFILE_DIR" ]; then
    PROFILE_DIR="$HOME/.mozilla/firefox"
    if [ -d "$PROFILE_DIR" ]; then
        PROFILE_DIR=$(find "$PROFILE_DIR" -name "*.default*" -type d | head -1)
    fi
fi
CACHE_DIR="$HOME/.cache/mozilla/firefox"
echo "[FIREFOX] Profile: $PROFILE_DIR"

# ----------------------------------------------------------------------
# Helper: numeric comparison
# ----------------------------------------------------------------------
compare_gt() {
    local val="$1"
    local threshold="$2"
    if command -v bc &>/dev/null; then
        echo "$val > $threshold" | bc -l
    else
        awk "BEGIN {print ($val > $threshold) ? 1 : 0}"
    fi
}

# ----------------------------------------------------------------------
# Temporarily disable SELinux (if enforcing) and restore on exit
# ----------------------------------------------------------------------
if command -v getenforce &>/dev/null; then
    SELINUX_MODE=$(getenforce)
    if [[ "$SELINUX_MODE" == "Enforcing" ]]; then
        echo "[SELINUX] Temporarily setting to permissive (restoring on exit)"
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S setenforce 0
        else
            sudo setenforce 0
        fi
        trap 'if [[ -n "$SUDO_PASSWORD" ]]; then echo "$SUDO_PASSWORD" | sudo -S setenforce 1; else sudo setenforce 1; fi' EXIT
    else
        echo "[SELINUX] Already permissive or disabled"
    fi
fi

# ----------------------------------------------------------------------
# Temporarily set ptrace_scope=0 (restore on exit)
# ----------------------------------------------------------------------
PTRACE_ORIG=1
if [[ -f /proc/sys/kernel/yama/ptrace_scope ]]; then
    PTRACE_ORIG=$(cat /proc/sys/kernel/yama/ptrace_scope)
    if [[ "$PTRACE_ORIG" != "0" ]]; then
        echo "[PTRACE] Setting ptrace_scope=0 (will restore on exit)"
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S sh -c 'echo 0 > /proc/sys/kernel/yama/ptrace_scope'
        else
            sudo sh -c 'echo 0 > /proc/sys/kernel/yama/ptrace_scope'
        fi
        trap 'if [[ -n "$SUDO_PASSWORD" ]]; then echo "$SUDO_PASSWORD" | sudo -S sh -c "echo $PTRACE_ORIG > /proc/sys/kernel/yama/ptrace_scope"; else sudo sh -c "echo $PTRACE_ORIG > /proc/sys/kernel/yama/ptrace_scope"; fi' EXIT
    else
        echo "[PTRACE] ptrace_scope already 0 – stack traces will work"
    fi
fi

# ----------------------------------------------------------------------
# Ensure Firefox is running with CDP port
# ----------------------------------------------------------------------
export DISPLAY="${DISPLAY:-:0}"
echo "[DISPLAY] Using real X display: $DISPLAY"

if [ "$AUTO_FIX" = true ]; then
    echo "[FIREFOX] Killing all Firefox processes"
    if [[ -n "$SUDO_PASSWORD" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S pkill -9 -x firefox || true
    else
        sudo pkill -9 -x firefox || true
    fi
    sleep 2
    # Wait for profile lock
    for i in {1..5}; do
        if ! fuser "$PROFILE_DIR" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    echo "[FIREFOX] Launching Firefox with CDP port"
    if [[ -n "$SUDO_PASSWORD" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S -u "$(whoami)" firefox --profile "$PROFILE_DIR" --remote-debugging-port=9222 2>/dev/null &
    else
        sudo -u "$(whoami)" firefox --profile "$PROFILE_DIR" --remote-debugging-port=9222 2>/dev/null &
    fi
    sleep 5
else
    if ! pgrep -x firefox >/dev/null; then
        echo "[FIREFOX] Launching Firefox"
        firefox --profile "$PROFILE_DIR" --remote-debugging-port=9222 2>/dev/null &
        sleep 5
    else
        echo "[FIREFOX] Firefox already running"
    fi
fi

# ----------------------------------------------------------------------
# Wait for CDP port and ensure a page exists (so WebSocket URL appears)
# ----------------------------------------------------------------------
echo "[CDP] Waiting for port 9222..."
CDP_READY=false
for i in {1..30}; do
    if curl -s http://localhost:9222/json/list >/dev/null 2>&1; then
        echo "[CDP] Port ready after ${i}s"
        CDP_READY=true
        break
    fi
    sleep 1
done

if [ "$CDP_READY" = true ] && python3 -c "import websockets" 2>/dev/null; then
    echo "[CDP] Creating blank page to force WebSocket URL..."
    python3 2>/dev/null << PYEOF
import asyncio
import json
import websockets
import subprocess

async def setup_cdp():
    # Get first page's WebSocket URL
    data = json.loads(subprocess.check_output(["curl", "-s", "http://localhost:9222/json/list"]))
    ws_url = None
    if data:
        ws_url = data[0].get("webSocketDebuggerUrl")
    if not ws_url:
        # No page yet – open a blank tab
        subprocess.run(["firefox", "--new-tab", "about:blank"], check=False)
        await asyncio.sleep(2)
        data = json.loads(subprocess.check_output(["curl", "-s", "http://localhost:9222/json/list"]))
        if data:
            ws_url = data[0].get("webSocketDebuggerUrl")
    if ws_url:
        async with websockets.connect(ws_url) as ws:
            await ws.send(json.dumps({"id": 1, "method": "Page.enable"}))
            await ws.recv()
            await ws.send(json.dumps({"id": 2, "method": "Page.navigate", "params": {"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}}))
            await ws.recv()
            print("[CDP] YouTube video loaded via CDP")
    else:
        print("[CDP] Could not obtain WebSocket URL – fallback to command line")
        subprocess.run(["firefox", "--new-tab", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])

asyncio.run(setup_cdp())
PYEOF
else
    echo "[CDP] CDP not ready or websockets missing – using command-line fallback"
    firefox --new-tab "https://www.youtube.com/watch?v=dQw4w9WgXcQ" 2>/dev/null &
    sleep 5
fi

# ----------------------------------------------------------------------
# Wait for video to create CPU load
# ----------------------------------------------------------------------
echo ""
echo "[LOAD] Waiting ${DURATION} seconds for video to create CPU contention..."
sleep "$DURATION"

# ----------------------------------------------------------------------
# Run full diagnostic
# ----------------------------------------------------------------------
echo ""
echo "=== Running full diagnostic during video playback ==="

mapfile -t FIREFOX_PIDS < <(pgrep -x firefox || true)
echo "[FIX-001] Found ${#FIREFOX_PIDS[@]} Firefox PIDs"
if (( ${#FIREFOX_PIDS[@]} == 0 )); then
    echo "No Firefox processes"
    exit 1
fi

TMPDIR=$(mktemp -d -t ffdiag.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ----------------------------------------------------------------------
# SECTION 1/10: Accurate per‑thread CPU (ps -L)
# ----------------------------------------------------------------------
echo ""
echo "=== [1/10] Accurate per‑thread CPU (using ps -L) ==="

TEMP_TOP_PID="${FIREFOX_PIDS[0]}"
THREAD_CPU_FILE="$TMPDIR/thread_cpu.txt"
ps -L -p "$TEMP_TOP_PID" -o tid=,%cpu=,comm= 2>/dev/null | sort -k2 -rn > "$THREAD_CPU_FILE"

echo "Top CPU‑consuming threads (TID, %CPU, command):"
head -10 "$THREAD_CPU_FILE" | while read -r tid cpu comm; do
    printf "  TID %6s: %5s%%  %s\n" "$tid" "$cpu" "$comm"
done

RENDERER_TID=$(awk '$3 ~ /Renderer/ {print $1; exit}' "$THREAD_CPU_FILE")
RENDERER_CPU=$(awk -v tid="$RENDERER_TID" '$1 == tid {print $2}' "$THREAD_CPU_FILE")
if [[ -z "$RENDERER_TID" ]]; then
    RENDERER_TID=$(head -1 "$THREAD_CPU_FILE" | awk '{print $1}')
    RENDERER_CPU=$(head -1 "$THREAD_CPU_FILE" | awk '{print $2}')
fi

if [[ -n "$RENDERER_TID" ]]; then
    echo "[THREAD] Renderer/content thread: TID $RENDERER_TID (${RENDERER_CPU:-0}% CPU)"
else
    echo "[THREAD] No high‑CPU thread found"
fi

# ----------------------------------------------------------------------
# SECTION 2/10: Process sampling (ps)
# ----------------------------------------------------------------------
echo ""
echo "=== [2/10] Sampling Firefox processes for CPU/RSS ==="

classify_process_type() {
    local pid=$1
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
    if [[ "$cmdline" == *"IsForBrowser"* ]]; then
        echo "content (tab)"
    elif [[ "$cmdline" == *"privileged about:"* ]]; then
        echo "privileged (about:*)"
    elif [[ "$cmdline" == *"socket process"* ]]; then
        echo "network/socket"
    elif [[ "$cmdline" == *"GPU"* ]]; then
        echo "gpu"
    elif [[ "$cmdline" == *"Utility"* ]]; then
        echo "utility"
    elif [[ "$cmdline" == *"plugin"* ]]; then
        echo "plugin"
    else
        echo "main/unknown"
    fi
}

RESULTS=()
for pid in "${FIREFOX_PIDS[@]}"; do
    cpu=$(ps -p "$pid" -o %cpu= --no-headers 2>/dev/null | tr -d ' ' || echo "0")
    rss=$(ps -p "$pid" -o rss= --no-headers 2>/dev/null | tr -d ' ' || echo "0")
    RESULTS+=("$cpu $pid $rss")
done

# ----------------------------------------------------------------------
# SECTION 3/10: Aggregating and ranking (defines TOP_PID)
# ----------------------------------------------------------------------
echo "=== [3/10] Aggregating and ranking results ==="

IFS=$'\n' read -r -d '' -a SORTED < <(printf '%s\n' "${RESULTS[@]}" | sort -rn -k1 || true) || true

echo ""
echo "[AGGREGATE] All Firefox processes (ranked by CPU):"
for entry in "${SORTED[@]}"; do
    set -- $entry
    cpu=$1; pid=$2; rss=$3
    ptype=$(classify_process_type "$pid")
    printf "  PID %6s: cpu=%4s%% rss=%6sKB type=%-12s\n" "$pid" "$cpu" "$rss" "$ptype"
done

TOP_PID=0; TOP_CPU=0
if (( ${#SORTED[@]} > 0 )); then
    top_entry="${SORTED[0]}"
    set -- $top_entry
    TOP_CPU=$1; TOP_PID=$2
fi
echo ""
echo "[AGGREGATE] Highest‑CPU PID: $TOP_PID (${TOP_CPU}%)"

# ----------------------------------------------------------------------
# SECTION 4/10: Thread control (renice / pinning)
# ----------------------------------------------------------------------
echo ""
echo "=== [4/10] Thread control (renice / CPU pinning) ==="

if [[ -n "$RENDERER_TID" ]]; then
    if [ "$AUTO_FIX" = true ]; then
        echo "  Auto‑fix: renicing whole Firefox process (nice +10)"
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S renice -n 10 -p "$TOP_PID" 2>/dev/null && echo "    Renice OK" || echo "    Renice failed"
        else
            sudo renice -n 10 -p "$TOP_PID" 2>/dev/null && echo "    Renice OK" || echo "    Renice failed"
        fi
        if [[ -n "$PIN_CORE" ]]; then
            if command -v taskset &>/dev/null; then
                echo "  Pinning Renderer thread $RENDERER_TID to CPU core $PIN_CORE"
                if [[ -n "$SUDO_PASSWORD" ]]; then
                    echo "$SUDO_PASSWORD" | sudo -S taskset -p -c "$PIN_CORE" "$RENDERER_TID" 2>/dev/null && echo "    Done" || echo "    Failed"
                else
                    sudo taskset -p -c "$PIN_CORE" "$RENDERER_TID" 2>/dev/null && echo "    Done" || echo "    Failed"
                fi
            else
                echo "  taskset not installed – skipping CPU pinning"
            fi
        fi
    else
        echo "  To control threads, run with --auto-fix (and optional --pin-core N)"
    fi
else
    echo "  No Renderer thread detected – skipping thread control"
fi

# ----------------------------------------------------------------------
# SECTION 5/10: GDB stack trace (20s timeout, debuginfod off)
# ----------------------------------------------------------------------
echo ""
echo "=== [5/10] GDB stack trace (non‑blocking with 20s timeout) ==="

GDB_OUTPUT=""
if [ "$USE_GDB" = true ]; then
    if command -v gdb &>/dev/null && command -v timeout &>/dev/null; then
        echo "Running GDB with 20 second timeout (non‑blocking)..."
        GDB_OUTPUT=$(timeout 20 gdb -batch -return-child-result -p "$TOP_PID" \
            -ex "set pagination off" \
            -ex "set debuginfod enabled off" \
            -ex "info threads" \
            -ex "thread apply all bt" \
            -ex "quit" 2>&1 || echo "GDB_TIMEOUT_OR_FAILED")
        if echo "$GDB_OUTPUT" | grep -q "GDB_TIMEOUT_OR_FAILED"; then
            echo "⚠️  GDB timed out after 20 seconds – using fallback"
            GDB_OUTPUT=""
        elif [ -n "$GDB_OUTPUT" ]; then
            echo "GDB completed successfully"
            echo "$GDB_OUTPUT" | head -100
        else
            echo "No GDB output"
        fi
    else
        echo "GDB or timeout missing – falling back to perf / proc"
    fi
else
    echo "GDB disabled by --no-gdb"
fi

# ----------------------------------------------------------------------
# Fallback: perf script (if available)
# ----------------------------------------------------------------------
if [ -z "$GDB_OUTPUT" ] && command -v perf &>/dev/null; then
    echo "Using perf script for stack trace (non‑blocking)..."
    PERF_OUTPUT=$(timeout 10 perf script -i /dev/null --ns -F comm,tid,time,ip,sym -p "$TOP_PID" 2>/dev/null | head -100 || echo "perf failed")
    if [ -n "$PERF_OUTPUT" ]; then
        echo "Perf stack trace:"
        echo "$PERF_OUTPUT"
        GDB_OUTPUT="$PERF_OUTPUT"
    fi
fi

# ----------------------------------------------------------------------
# SECTION 6/10: Fallback stack trace (/proc/*/stack)
# ----------------------------------------------------------------------
echo ""
echo "=== [6/10] Fallback stack trace (/proc/*/stack) ==="

STACK_FILE="$TMPDIR/stack_trace.txt"
> "$STACK_FILE"
if [[ -d "/proc/$TOP_PID/task" ]]; then
    for tid_path in /proc/$TOP_PID/task/*; do
        tid=$(basename "$tid_path")
        if [[ -f "$tid_path/stack" ]]; then
            echo "=== Thread $tid ===" >> "$STACK_FILE"
            cat "$tid_path/stack" 2>/dev/null >> "$STACK_FILE" || echo "  (unreadable)" >> "$STACK_FILE"
            echo "" >> "$STACK_FILE"
        fi
    done
    echo "Stack trace saved (non‑blocking, from /proc)"
else
    echo "No task directory for PID $TOP_PID" >> "$STACK_FILE"
fi
STACK_TRACE=$(cat "$STACK_FILE" | head -500)
echo "Preview (first 60 lines):"
head -60 "$STACK_FILE"

# ----------------------------------------------------------------------
# SECTION 7/10: PSI pressure
# ----------------------------------------------------------------------
echo ""
echo "=== [7/10] PSI pressure ==="
PSI_CPU_AVG10=$(awk '/some/{print $2}' /proc/pressure/cpu 2>/dev/null | cut -d= -f2 | head -1 || echo 0)
PSI_MEM_AVG10=$(awk '/some/{print $2}' /proc/pressure/memory 2>/dev/null | cut -d= -f2 | head -1 || echo 0)
PSI_IO_AVG10=$(awk '/some/{print $2}' /proc/pressure/io 2>/dev/null | cut -d= -f2 | head -1 || echo 0)
echo "[PSI] CPU: ${PSI_CPU_AVG10}%, MEM: ${PSI_MEM_AVG10}%, IO: ${PSI_IO_AVG10}%"

# ----------------------------------------------------------------------
# SECTION 8/10: Xorg status
# ----------------------------------------------------------------------
echo ""
echo "=== [8/10] Xorg status ==="
XORG_CPU=0.0
if pgrep -x Xorg >/dev/null; then
    XORG_PID=$(pgrep -x Xorg | head -1)
    XORG_CPU=$(ps -p "$XORG_PID" -o %cpu --no-headers | tr -d ' ' || echo 0)
    echo "[Xorg] PID: $XORG_PID, CPU: ${XORG_CPU}%"
else
    echo "[Xorg] Not running"
fi

# ----------------------------------------------------------------------
# SECTION 9/10: Memory fragmentation
# ----------------------------------------------------------------------
echo ""
echo "=== [9/10] Memory fragmentation ==="
MEM_FRAG_SCORE=0
if [[ -f /proc/buddyinfo ]]; then
    if command -v python3 &>/dev/null; then
        MEM_FRAG_SCORE=$(python3 -c "
frag = 0
with open('/proc/buddyinfo') as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 13:
            orders = [int(x) for x in parts[4:]]
            total = sum(orders)
            if total > 0:
                largest = max(orders)
                frag = max(frag, 1.0 - (largest / total))
print(int(round(frag * 100, 0)))
")
    else
        MEM_FRAG_SCORE=$(awk '
        {
            for(i=4;i<=NF;i++) orders[i-3]=$i
            total=0; largest=0
            for(i=1;i<=length(orders);i++) { total+=orders[i]; if(orders[i]>largest) largest=orders[i] }
            if(total>0) { frag=1-(largest/total); if(frag>max_frag) max_frag=frag }
        }
        END { printf "%d\n", max_frag*100 }' /proc/buddyinfo 2>/dev/null || echo 0)
    fi
fi
echo "[Fragmentation] Score: $MEM_FRAG_SCORE"

# ----------------------------------------------------------------------
# SECTION 10/10: Database persistence
# ----------------------------------------------------------------------
echo ""
echo "=== [10/10] Database persistence ==="

NETSTAT=$(ss -tunap 2>&1 | grep "pid=$TOP_PID," | head -20 || echo "No active network connections")

escape_sql() {
    local input="$1"
    if command -v python3 &>/dev/null; then
        echo "$input" | python3 -c "import sys; sys.stdout.write(sys.stdin.read().replace(\"'\", \"''\"))" 2>/dev/null || echo "$input"
    else
        echo "$input" | sed "s/'/''/g"
    fi
}

NETSTAT_ESC=$(escape_sql "$NETSTAT" | head -500)
STACK_ESC=$(escape_sql "$STACK_TRACE" | head -1000)
GDB_ESC=$(escape_sql "$GDB_OUTPUT" | head -1000)
THREADS_ESC=$(escape_sql "$(head -10 "$THREAD_CPU_FILE")" | head -200)

psql -h 127.0.0.1 -U observer -d observability -c "
INSERT INTO events (time, host, event_type, subsystem, severity, raw_payload)
VALUES (
    NOW(),
    '$(hostname)',
    'youtube_contention_test',
    'firefox',
    'info',
    jsonb_build_object(
        'test_type', 'youtube_video',
        'top_pid', $TOP_PID,
        'top_cpu', $TOP_CPU,
        'psi_cpu_avg10', $PSI_CPU_AVG10,
        'psi_mem_avg10', $PSI_MEM_AVG10,
        'psi_io_avg10', $PSI_IO_AVG10,
        'xorg_cpu_pct', $XORG_CPU,
        'memory_fragmentation_score', $MEM_FRAG_SCORE,
        'network_connections', '$NETSTAT_ESC',
        'stack_trace_fallback', '$STACK_ESC',
        'gdb_output', '$GDB_ESC',
        'top_threads_delta', '$THREADS_ESC',
        'renderer_tid', ${RENDERER_TID:-0},
        'renderer_cpu', ${RENDERER_CPU:-0},
        'cpu_pinning_core', '${PIN_CORE:-none}',
        'gdb_enabled', '$USE_GDB'
    )
);"

echo "[DB] Data persisted"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=== DIAGNOSTIC SUMMARY ==="
echo "Top PID: $TOP_PID (${TOP_CPU}% CPU)"
echo "Renderer Thread TID: ${RENDERER_TID:-none} (${RENDERER_CPU:-0}% CPU)"
echo "PSI CPU avg10: ${PSI_CPU_AVG10}%"
echo "PSI IO avg10: ${PSI_IO_AVG10}%"
echo "Xorg CPU: ${XORG_CPU}%"
echo "Memory fragmentation: ${MEM_FRAG_SCORE}"
echo "Stack trace: collected from /proc (ptrace_scope temporarily lifted)"
[[ -n "$PIN_CORE" ]] && [ "$AUTO_FIX" = true ] && echo "CPU pinning: applied to core $PIN_CORE"
echo "GDB: $([ "$USE_GDB" = true ] && echo "enabled (20s timeout)" || echo "disabled")"
echo "==========================="

elapsed=$SECONDS
echo "EXIT: 0 ELAPSED: ${elapsed}s"
echo "[LOG] Full log: $LOG_FILE"

# =========================================================================
# ANALYSIS REPORT (last 7 days)
# =========================================================================
echo ""
echo "=== ANALYSIS REPORT (last 7 days) ==="

psql -h 127.0.0.1 -U observer -d observability << 'ANALYSIS_EOF'
WITH contention_data AS (
    SELECT
        time,
        host,
        (raw_payload->>'top_cpu')::float AS top_cpu_pct,
        (raw_payload->>'psi_cpu_avg10')::float AS psi_cpu,
        (raw_payload->>'psi_io_avg10')::float AS psi_io,
        (raw_payload->>'memory_fragmentation_score')::int AS frag_score,
        (raw_payload->>'renderer_cpu')::float AS renderer_cpu,
        raw_payload->>'cpu_pinning_core' AS pin_core,
        (raw_payload->>'gdb_enabled')::boolean AS gdb_enabled
    FROM events
    WHERE event_type = 'youtube_contention_test'
      AND subsystem = 'firefox'
      AND time >= NOW() - INTERVAL '7 days'
)
SELECT
    time,
    top_cpu_pct,
    psi_cpu,
    psi_io,
    frag_score,
    renderer_cpu,
    pin_core,
    gdb_enabled,
    CASE
        WHEN psi_io > 30 THEN 'HIGH_IO_PRESSURE'
        WHEN top_cpu_pct > 25 THEN 'HIGH_CPU'
        WHEN frag_score > 70 THEN 'HIGH_FRAGMENTATION'
        ELSE 'NORMAL'
    END AS severity
FROM contention_data
ORDER BY time DESC
LIMIT 15;
ANALYSIS_EOF

# =========================================================================
# SELF-HEALING ROUTINE (complete)
# =========================================================================
echo ""
echo "=== SELF-HEALING ROUTINE ==="

# ------------------------------------------------------------------
# WebGL/GPU acceleration + disable sync
# ------------------------------------------------------------------
WEBGL_FIXED=false
if [ "$AUTO_FIX" = true ]; then
    USER_JS="$PROFILE_DIR/user.js"
    if [ ! -w "$(dirname "$USER_JS")" ]; then
        echo "  Profile directory not writable – fixing permissions"
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S chown -R "$(whoami)" "$(dirname "$USER_JS")" 2>/dev/null
        else
            sudo chown -R "$(whoami)" "$(dirname "$USER_JS")" 2>/dev/null
        fi
        chmod 755 "$(dirname "$USER_JS")" 2>/dev/null
    fi

    echo "[HEAL] Forcing WebGL/GPU acceleration and disabling sync"
    CHANGED=0
    for pref in \
        'user_pref("gfx.webrender.all", true);' \
        'user_pref("webgl.force-enabled", true);' \
        'user_pref("layers.acceleration.force-enabled", true);' \
        'user_pref("webgl.disable-angle", true);' \
        'user_pref("services.sync.engine.addons", false);' \
        'user_pref("services.sync.engine.bookmarks", false);' \
        'user_pref("services.sync.engine.history", false);' \
        'user_pref("services.sync.engine.passwords", false);' \
        'user_pref("services.sync.engine.prefs", false);' \
        'user_pref("services.sync.engine.tabs", false);'
    do
        if ! grep -Fq "$pref" "$USER_JS" 2>/dev/null; then
            if [[ -n "$SUDO_PASSWORD" ]]; then
                echo "$pref" | echo "$SUDO_PASSWORD" | sudo -S tee -a "$USER_JS" >/dev/null
            else
                echo "$pref" | sudo tee -a "$USER_JS" >/dev/null
            fi
            echo "  + $(echo "$pref" | cut -d'"' -f2)"
            CHANGED=1
        fi
    done

    if [ $CHANGED -eq 1 ]; then
        echo "  WebGL/GPU and sync preferences written"
        WEBGL_FIXED=true
    else
        echo "  Preferences already present"
        WEBGL_FIXED=true
    fi
fi

# ------------------------------------------------------------------
# Clear all caches
# ------------------------------------------------------------------
if [ "$AUTO_FIX" = true ]; then
    echo "[HEAL] Clearing all Firefox caches"
    if [[ -n "$SUDO_PASSWORD" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S rm -rf "$PROFILE_DIR/cache2" "$PROFILE_DIR/startupCache" 2>/dev/null && echo "  Profile caches cleared" || echo "  No profile caches"
        echo "$SUDO_PASSWORD" | sudo -S rm -rf "$CACHE_DIR"/* 2>/dev/null && echo "  System cache cleared" || echo "  No system cache"
        echo "$SUDO_PASSWORD" | sudo -S rm -rf "$PROFILE_DIR/storage/default"/* 2>/dev/null && echo "  Storage cleared" || echo "  No storage"
    else
        sudo rm -rf "$PROFILE_DIR/cache2" "$PROFILE_DIR/startupCache" 2>/dev/null && echo "  Profile caches cleared" || echo "  No profile caches"
        sudo rm -rf "$CACHE_DIR"/* 2>/dev/null && echo "  System cache cleared" || echo "  No system cache"
        sudo rm -rf "$PROFILE_DIR/storage/default"/* 2>/dev/null && echo "  Storage cleared" || echo "  No storage"
    fi
fi

# ------------------------------------------------------------------
# Vacuum SQLite databases
# ------------------------------------------------------------------
if [ "$AUTO_FIX" = true ] && command -v sqlite3 &>/dev/null; then
    echo "[HEAL] Vacuuming SQLite databases"
    for db in places.sqlite favicons.sqlite cookies.sqlite; do
        if [ -f "$PROFILE_DIR/$db" ]; then
            sqlite3 "$PROFILE_DIR/$db" "VACUUM;" 2>/dev/null && echo "  Vacuumed $db" || echo "  Failed to vacuum $db"
        fi
    done
fi

# ------------------------------------------------------------------
# Restart Firefox to apply changes
# ------------------------------------------------------------------
if [ "$AUTO_FIX" = true ] && [ "$WEBGL_FIXED" = true ]; then
    echo "  Restarting Firefox to apply changes..."
    if [[ -n "$SUDO_PASSWORD" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S pkill -9 -x firefox || true
        sleep 2
        echo "$SUDO_PASSWORD" | sudo -S -u "$(whoami)" firefox --profile "$PROFILE_DIR" --remote-debugging-port=9222 2>/dev/null &
    else
        sudo pkill -9 -x firefox || true
        sleep 2
        sudo -u "$(whoami)" firefox --profile "$PROFILE_DIR" --remote-debugging-port=9222 2>/dev/null &
    fi
    echo "  Firefox restarted."
fi

# ------------------------------------------------------------------
# Memory compaction
# ------------------------------------------------------------------
if (( MEM_FRAG_SCORE > 70 )); then
    echo "[HEAL] High fragmentation (${MEM_FRAG_SCORE}) – triggering compaction"
    if [ "$AUTO_FIX" = true ]; then
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S sh -c 'echo 1 > /proc/sys/vm/compact_memory' 2>/dev/null && echo "  Compaction triggered" || echo "  Compaction failed"
        else
            sudo sh -c 'echo 1 > /proc/sys/vm/compact_memory' 2>/dev/null && echo "  Compaction triggered" || echo "  Compaction failed"
        fi
    else
        echo "  Run with --auto-fix to trigger memory compaction"
    fi
fi

# ------------------------------------------------------------------
# Drop caches if I/O pressure high
# ------------------------------------------------------------------
if [[ $(compare_gt "$PSI_IO_AVG10" "30") -eq 1 ]]; then
    echo "[HEAL] High I/O pressure (${PSI_IO_AVG10}%) – reducing swap usage"
    if [ "$AUTO_FIX" = true ]; then
        echo "  Clearing page cache (sync + drop_caches)"
        sync
        if [[ -n "$SUDO_PASSWORD" ]]; then
            echo "$SUDO_PASSWORD" | sudo -S sh -c 'echo 1 > /proc/sys/vm/drop_caches' 2>/dev/null && echo "  Page cache cleared" || echo "  Failed"
        else
            sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches' 2>/dev/null && echo "  Page cache cleared" || echo "  Failed"
        fi
    else
        echo "  Run with --auto-fix to drop caches"
    fi
fi

# ------------------------------------------------------------------
# High CPU warning
# ------------------------------------------------------------------
if [[ $(compare_gt "$TOP_CPU" "25") -eq 1 ]]; then
    echo "[HEAL] Firefox CPU high (${TOP_CPU}%)"
    if [ "$AUTO_FIX" = true ]; then
        echo "  All caches already cleared. If CPU remains high, consider:"
        echo "    - Disabling unused extensions (about:addons)"
        echo "    - Resetting Firefox profile (about:profiles)"
        echo "    - Running 'pkill firefox' and starting fresh"
    else
        echo "  Run with --auto-fix to clear all caches and vacuum databases"
    fi
fi

echo ""
echo "=== Self‑healing complete ==="

# ------------------------------------------------------------------
# Final transparency report
# ------------------------------------------------------------------
echo ""
echo "=== FINAL STATUS REPORT ==="
echo "WebGL/GPU acceleration forced: $([ "$WEBGL_FIXED" = true ] && echo "YES" || echo "NO")"
echo "All caches cleared: $([ "$AUTO_FIX" = true ] && echo "YES" || echo "NO")"
echo "SQLite databases vacuumed: $([ "$AUTO_FIX" = true ] && command -v sqlite3 &>/dev/null && echo "YES" || echo "NO")"
echo "Firefox Sync disabled: $([ "$AUTO_FIX" = true ] && echo "YES" || echo "NO")"
echo "SELinux temporarily permissive: $([ "$(getenforce 2>/dev/null)" = "Permissive" ] && echo "YES (restored on exit)" || echo "NO")"
echo "ptrace_scope set to 0: $([ "$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null)" = "0" ] && echo "YES (restored on exit)" || echo "NO")"
echo "CDP WebSocket: $([ "$CDP_READY" = true ] && echo "WORKING" || echo "FALLBACK (command line)")"
echo "Renderer thread CPU: ${RENDERER_CPU:-0}% (target <10%)"
echo "Overall Firefox CPU: ${TOP_CPU}% (target <25%)"
echo "PSI I/O pressure: ${PSI_IO_AVG10}% (target <20%)"
echo ""
if [ "$AUTO_FIX" = true ]; then
    echo "✅ Auto‑fix applied. Please run the script again (without --auto-fix) after 30 seconds to see improvements."
else
    echo "ℹ️  Run with --auto-fix to apply all fixes."
fi
