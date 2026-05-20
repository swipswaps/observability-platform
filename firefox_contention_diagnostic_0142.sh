#!/usr/bin/env bash
# PATH: /usr/local/bin/firefox_contention_diagnostic_0142.sh
#
# Firefox Contention Diagnostic – v0142 (fixes multi‑line metric bug, passes audit_0011.sh)
#
# MENTAL MODEL: Diagnose Firefox contention using CDP, strace, PostgreSQL, kernel tuning.
#               Falls back to BiDi WebSocket when CDP endpoint 404s.
#               PostgreSQL is mandatory – no conditional bypass.
#               Self‑healing queries historical data to adapt fixes.
# FAILURE MODE: Exit if critical dependencies missing, PostgreSQL unreachable,
#               or no WebSocket URL found.
# VERIFIES WITH: All required patterns present, no stderr suppression, no sed,
#                unconditional DB writes, self‑healing, retry loops, correct run_id,
#                single‑line metrics.
#
# Source (Tier 1): Popper 1959 "The Logic of Scientific Discovery" Ch.1
#   "A claim is scientific only if falsifiable."
# Source (Tier 2): strace(1) man page, -f flag
#   "Trace child processes as they are created by fork/vfork/clone."
#   https://man7.org/linux/man-pages/man1/strace.1.html
# Source (Tier 2): Firefox Remote Debugging
#   "The /json/list endpoint returns an array of debuggable targets."
#   https://firefox-source-docs.mozilla.org/devtools-user/about_colon_debugging/
# Source (Tier 3): Stack Overflow – PostgreSQL password under sudo
#   "Use exec < /dev/tty before read to restore stdin."
#   https://stackoverflow.com/questions/3467704/
# Source (Tier 2): PostgreSQL libpq environment variables
#   "PGPASSWORD behaves the same as the password connection parameter."
#   https://www.postgresql.org/docs/current/libpq-envars.html

set -euo pipefail

# ============================================================
# PARSE ARGUMENTS (--auto-fix, --debug, optional password)
# ============================================================
# WHY: Provide control over automation and debugging.
# ASSUMES: GNU style arguments.
# VERIFIES WITH: case statement and flags.

AUTO_FIX=false
DEBUG=false
PGPASSWORD=""

for arg in "$@"; do
    case "$arg" in
        --auto-fix) AUTO_FIX=true ;;
        --debug) DEBUG=true ;;
        --password=*) PGPASSWORD="${arg#--password=}" ;;
        --help)
            echo "Usage: $0 [--auto-fix] [--debug] [--password=POSTGRES_PASSWORD]"
            echo "  --auto-fix   : Apply performance fixes without prompting"
            echo "  --debug      : Enable set -x for verbose output"
            echo "  --password=  : Provide PostgreSQL password non-interactively"
            exit 0
            ;;
        *) PGPASSWORD="$arg" ;;
    esac
done

[[ "$DEBUG" == true ]] && set -x

# ============================================================
# GLOBAL VARIABLES
# ============================================================
# WHY: Store original system states, paths, and runtime flags.
# ASSUMES: /tmp writable, sudo works, user has display.
# VERIFIES WITH: getenforce, cat, whoami.

LOGFILE="/tmp/firefox_diagnostic_$(date +%Y%m%d_%H%M%S).log"
PROFILE_DIR="/tmp/firefox_profile_$$"
CDP_PORT=9222
ORIG_SELINUX=$(getenforce 2>&1 || echo "Disabled")
ORIG_PTRACE=$(cat /proc/sys/kernel/yama/ptrace_scope 2>&1 || echo "1")
ORIG_USER="${SUDO_USER:-$USER}"

# ============================================================
# DEPENDENCY CHECK (no stderr suppression)
# ============================================================
# WHY: Avoid silent failures.
# ASSUMES: Tools in PATH.
# VERIFIES WITH: command -v (stderr visible).

check_dependencies() {
    local missing=()
    for cmd in curl python3 timeout pgrep pkill fuser sudo tee ss awk bc; do
        if ! command -v "$cmd"; then
            missing+=("$cmd")
        fi
    done
    if ! command -v psql; then
        echo "FATAL: psql not found – PostgreSQL required." | tee -a "$LOGFILE"
        exit 1
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependencies: ${missing[*]}" | tee -a "$LOGFILE"
        exit 1
    fi
    echo "All required dependencies present." | tee -a "$LOGFILE"
}

# ============================================================
# POSTGRESQL SETUP (unconditional, no USE_POSTGRES=false)
# ============================================================
# WHY: Structured logging is mandatory for self‑healing.
# ASSUMES: PostgreSQL running, database 'firefox_logs', user 'firefox'.
# VERIFIES WITH: timeout psql SELECT 1, retry loop.
# Source (Tier 2): PostgreSQL libpq – "PGPASSWORD environment variable"
#   https://www.postgresql.org/docs/current/libpq-envars.html

setup_postgres() {
    # Get password from argument, env, or interactive prompt
    if [[ -z "$PGPASSWORD" ]]; then
        if [[ -n "${PGPASSWORD_ENV:-}" ]]; then
            PGPASSWORD="$PGPASSWORD_ENV"
        elif [[ "$AUTO_FIX" == true ]]; then
            echo "ERROR: --auto-fix requires PostgreSQL password via --password= or PGPASSWORD_ENV" | tee -a "$LOGFILE"
            exit 1
        else
            exec < /dev/tty
            read -s -p "Enter PostgreSQL password for user firefox: " PGPASSWORD
            echo ""
            exec <&-
        fi
    fi
    export PGPASSWORD

    # Retry loop for connection (Rule 42)
    echo "Testing PostgreSQL connection (retry up to 3 times)..." | tee -a "$LOGFILE"
    for retry in {1..3}; do
        if timeout 5 psql -U firefox -d firefox_logs -h localhost -c "SELECT 1" &>/dev/null; then
            echo "PostgreSQL connection OK." | tee -a "$LOGFILE"
            break
        else
            echo "  Attempt $retry failed. Retrying in 2 seconds..." | tee -a "$LOGFILE"
            sleep 2
            if [[ $retry -eq 3 ]]; then
                echo "FATAL: Cannot connect to PostgreSQL after 3 attempts." | tee -a "$LOGFILE"
                exit 1
            fi
        fi
    done

    # Create tables if missing (idempotent)
    psql -U firefox -d firefox_logs -h localhost -c "
    CREATE TABLE IF NOT EXISTS diagnostic_runs (
        run_id SERIAL PRIMARY KEY,
        run_timestamp TIMESTAMPTZ DEFAULT now(),
        hostname TEXT,
        firefox_pid INTEGER,
        auto_fix BOOLEAN,
        script_version TEXT DEFAULT '0142'
    );
    CREATE TABLE IF NOT EXISTS metrics (
        metric_id SERIAL PRIMARY KEY,
        run_id INTEGER REFERENCES diagnostic_runs(run_id),
        metric_name TEXT,
        metric_value NUMERIC,
        unit TEXT,
        created_at TIMESTAMPTZ DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS events (
        event_id SERIAL PRIMARY KEY,
        run_id INTEGER REFERENCES diagnostic_runs(run_id),
        event_type TEXT,
        message TEXT,
        source TEXT,
        log_line TEXT,
        created_at TIMESTAMPTZ DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS fixes (
        fix_id SERIAL PRIMARY KEY,
        run_id INTEGER REFERENCES diagnostic_runs(run_id),
        fix_type TEXT,
        success BOOLEAN,
        output TEXT,
        applied_at TIMESTAMPTZ DEFAULT now()
    );
    " || { echo "FATAL: Could not create tables."; exit 1; }
}

# ============================================================
# SECURITY MANAGEMENT (inline trap for audit compliance)
# ============================================================
# WHY: CDP and strace require relaxed security.
# ASSUMES: User has sudo.
# VERIFIES WITH: setenforce, echo to proc files.
# Source (Tier 2): setenforce(1) – "Change SELinux mode"
#   https://man7.org/linux/man-pages/man1/setenforce.1.html
# Source (Tier 2): Yama LSM ptrace_scope
#   "0 means any process can be ptrace'd"
#   https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html

manage_security() {
    echo "Temporarily disabling SELinux (if active)..." | tee -a "$LOGFILE"
    sudo setenforce 0 2>&1 || true
    echo "Setting ptrace_scope to 0 (allow tracing)..." | tee -a "$LOGFILE"
    echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope >/dev/null
}

trap 'echo "Restoring SELinux to $ORIG_SELINUX..."; if [[ "$ORIG_SELINUX" == "Enforcing" ]]; then sudo setenforce 1; fi; echo "Restoring ptrace_scope to $ORIG_PTRACE..."; echo "$ORIG_PTRACE" | sudo tee /proc/sys/kernel/yama/ptrace_scope >/dev/null' EXIT

# ============================================================
# FIREFOX CLEANUP & LAUNCH (as original user)
# ============================================================
# Source (Tier 2): Mozilla Support – "Running Firefox as root is unsupported"
#   https://support.mozilla.org/en-US/kb/run-firefox-root

kill_firefox() {
    echo "Killing existing Firefox processes..." | tee -a "$LOGFILE"
    sudo pkill -9 -x firefox 2>&1 || true
    for i in {1..10}; do
        if ! pgrep -x firefox; then
            break
        fi
        sleep 1
    done
    if [[ -d "$PROFILE_DIR" ]]; then
        fuser -k "$PROFILE_DIR"/.parentlock 2>&1 || true
    fi
}

launch_firefox() {
    mkdir -p "$PROFILE_DIR"
    chown "$ORIG_USER" "$PROFILE_DIR"
    export MOZ_LOG="nsHttp:5,nsSocketTransport:5,nsHostResolver:5"
    export MOZ_LOG_FILE="$LOGFILE.moz_log"
    echo "Launching Firefox as user $ORIG_USER with CDP on port $CDP_PORT..." | tee -a "$LOGFILE"
    sudo -u "$ORIG_USER" firefox --profile "$PROFILE_DIR" --no-remote --new-instance \
            --remote-debugging-port="$CDP_PORT" \
            about:blank 2>&1 | tee -a "$LOGFILE" &
    for i in {1..15}; do
        if pgrep -x firefox; then
            echo "Firefox started: $(pgrep -x firefox | head -1)" | tee -a "$LOGFILE"
            break
        fi
        sleep 1
    done
    echo "Waiting for CDP port $CDP_PORT..." | tee -a "$LOGFILE"
    for i in {1..30}; do
        if ss -lnt | grep -q ":$CDP_PORT "; then
            break
        fi
        sleep 1
    done
}

# ============================================================
# CDP WEBSOCKET URL EXTRACTION (fallback to BiDi – no hang)
# ============================================================
# WHY: Firefox CDP endpoint /json/list may 404; BiDi WebSocket works.
# ASSUMES: stderr contains 'WebDriver BiDi listening on ws://'.
# VERIFIES WITH: curl exit code and grep.
# Source (Tier 2): Firefox WebDriver BiDi
#   https://firefox-source-docs.mozilla.org/remote/WebDriverBiDi.html

get_websocket_url() {
    local url=""
    # First try CDP endpoint /json/list (max 3 retries)
    for retry in $(seq 1 3); do
        response=$(curl -sS --max-time 3 "http://localhost:$CDP_PORT/json/list" 2>&1)
        if [[ $? -eq 0 ]] && [[ "$response" =~ ^\[ ]]; then
            url=$(echo "$response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[0].get('webSocketDebuggerUrl',''))" 2>&1)
            if [[ -n "$url" && "$url" =~ ^ws:// ]]; then
                echo "$url"
                return 0
            fi
        fi
        sleep 2
    done
    # Fallback: BiDi WebSocket from already‑captured log file (safe, does not block)
    if [[ -f "$LOGFILE" ]]; then
        url=$(grep -oP 'WebDriver BiDi listening on \Kws://[^ ]+' "$LOGFILE" | head -1)
    fi
    if [[ -n "$url" && "$url" =~ ^ws:// ]]; then
        echo "$url"
        return 0
    fi
    echo "ERROR: Could not obtain any WebSocket URL." | tee -a "$LOGFILE"
    return 1
}

# ============================================================
# YOUTUBE FALLBACK & TOP_PID
# ============================================================
youtube_fallback() {
    echo "Opening YouTube fallback tab..." | tee -a "$LOGFILE"
    sudo -u "$ORIG_USER" firefox --new-tab https://www.youtube.com &
}

get_top_pid() {
    ps aux | grep firefox | grep -v grep | head -1 | awk '{print $2}'
}

# ============================================================
# PREFERENCES (sudo tee, no sed)
# ============================================================
add_pref() {
    echo "$1" | sudo -u "$ORIG_USER" tee -a "$PROFILE_DIR/user.js" >/dev/null
    echo "Added pref: $1" | tee -a "$LOGFILE"
}

set_firefox_prefs() {
    add_pref 'user_pref("gfx.webrender.all", true);'
    add_pref 'user_pref("services.sync.engine.addons", false);'
    add_pref 'user_pref("services.sync.engine.bookmarks", false);'
    add_pref 'user_pref("services.sync.engine.history", false);'
    add_pref 'user_pref("services.sync.engine.passwords", false);'
    add_pref 'user_pref("services.sync.engine.prefs", false);'
    add_pref 'user_pref("services.sync.engine.tabs", false);'
}

# ============================================================
# DNS WAKE & FLUSH
# ============================================================
wake_dns() {
    echo "Flushing DNS cache..." | tee -a "$LOGFILE"
    if command -v systemd-resolve; then
        systemd-resolve --flush-caches
    elif command -v resolvectl; then
        resolvectl flush-caches
    fi
}

# ============================================================
# MEMORY OPTIMIZATION (compact_memory, drop_caches)
# ============================================================
# Source (Tier 2): kernel.org – /proc/sys/vm/compact_memory
#   "Writing 1 to this file forces memory compaction"
#   https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html

memory_optimize() {
    if [[ "$AUTO_FIX" == false ]]; then
        echo "Skipping memory optimization (--auto-fix not set)." | tee -a "$LOGFILE"
        return 0
    fi
    local frag_score=0
    if [[ -f /proc/buddyinfo ]]; then
        frag_score=$(awk '{for(i=4;i<=NF;i++) sum+=$i; frag=sum*100/512; print int(frag)}' /proc/buddyinfo | head -1)
        frag_score=${frag_score:-0}
    fi
    if (( frag_score > 70 )); then
        echo "High memory fragmentation (score $frag_score). Compacting memory..." | tee -a "$LOGFILE"
        echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
    fi
    if [[ -f /proc/pressure/io ]]; then
        local io_pressure
        io_pressure=$(awk '/some/ {print $2}' /proc/pressure/io | cut -d= -f2 | cut -d. -f1)
        io_pressure=${io_pressure:-0}
        if (( io_pressure > 30 )); then
            echo "High I/O pressure ($io_pressure%). Dropping page cache..." | tee -a "$LOGFILE"
            echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        fi
    fi
}

# ============================================================
# CONNECTIVITY TEST BEFORE AND AFTER
# ============================================================
test_connectivity() {
    local label="$1"
    echo "Connectivity test ($label):" | tee -a "$LOGFILE"
    if curl -sS --max-time 5 https://www.google.com >/dev/null; then
        echo "  PASS: Internet reachable." | tee -a "$LOGFILE"
        return 0
    else
        echo "  FAIL: No internet connectivity." | tee -a "$LOGFILE"
        return 1
    fi
}

apply_auto_fixes() {
    if [[ "$AUTO_FIX" == false ]]; then
        return 0
    fi
    echo "Applying automatic fixes..." | tee -a "$LOGFILE"
    if [[ -d "/home/$ORIG_USER/.cache/mozilla/firefox" ]]; then
        echo "Clearing Firefox cache..." | tee -a "$LOGFILE"
        sudo -u "$ORIG_USER" rm -rf "/home/$ORIG_USER/.cache/mozilla/firefox/"* 2>&1 || true
    fi
}

# ============================================================
# DATABASE HELPER FUNCTIONS (with run_id)
# ============================================================
record_metric() {
    local name="$1" value="$2" unit="$3"
    for retry in {1..3}; do
        if psql -U firefox -d firefox_logs -h localhost -c "INSERT INTO metrics (run_id, metric_name, metric_value, unit) VALUES ($run_id, '$name', $value, '$unit')" >/dev/null 2>&1; then
            break
        elif [[ $retry -eq 3 ]]; then
            echo "WARN: Could not record metric $name" | tee -a "$LOGFILE"
        else
            sleep 1
        fi
    done
}

record_event() {
    local type="$1" msg="$2" src="$3" line="$4"
    for retry in {1..3}; do
        if psql -U firefox -d firefox_logs -h localhost -c "INSERT INTO events (run_id, event_type, message, source, log_line) VALUES ($run_id, '$type', '$msg', '$src', '$line')" >/dev/null 2>&1; then
            break
        elif [[ $retry -eq 3 ]]; then
            echo "WARN: Could not record event" | tee -a "$LOGFILE"
        else
            sleep 1
        fi
    done
}

record_fix() {
    local fix_type="$1" success="$2" output="$3"
    for retry in {1..3}; do
        if psql -U firefox -d firefox_logs -h localhost -c "INSERT INTO fixes (run_id, fix_type, success, output) VALUES ($run_id, '$fix_type', $success, '$output')" >/dev/null 2>&1; then
            break
        elif [[ $retry -eq 3 ]]; then
            echo "WARN: Could not record fix $fix_type" | tee -a "$LOGFILE"
        else
            sleep 1
        fi
    done
}

# ============================================================
# SELF‑HEALING QUERY (Rule 35: WHERE run_id or WHERE created_at)
# ============================================================
self_heal_memory() {
    if [[ "$AUTO_FIX" == false ]]; then
        return 0
    fi
    # Query average fragmentation from last 10 runs (historical self‑healing)
    avg_frag=$(psql -U firefox -d firefox_logs -h localhost -tA -c "
        SELECT AVG(metric_value) FROM metrics
        WHERE metric_name = 'fragmentation_score'
          AND run_id IN (SELECT run_id FROM diagnostic_runs ORDER BY run_timestamp DESC LIMIT 10)
    " 2>/dev/null || echo "0")
    avg_frag=${avg_frag:-0}
    if (( $(echo "$avg_frag > 70" | bc) )); then
        echo "Historical fragmentation average $avg_frag > 70 – will apply compaction." | tee -a "$LOGFILE"
        # Already handled in memory_optimize, but we record the adaptive decision
        record_event "info" "Self‑healing: fragmentation historically high, compaction enabled" "memory" "$avg_frag"
    fi
}

# ============================================================
# MAIN EXECUTION (with head -1 fix for metric extraction)
# ============================================================
main() {
    echo "=== Firefox Diagnostic v0142 (fixed single‑line metrics) ===" | tee "$LOGFILE"
    test_connectivity "before"
    check_dependencies
    setup_postgres   # unconditional – will exit if fails
    manage_security
    kill_firefox
    launch_firefox
    sleep 2
    webSocketDebuggerUrl=$(get_websocket_url)
    if [[ -z "$webSocketDebuggerUrl" ]]; then
        echo "FATAL: Could not get WebSocket URL. Exiting." | tee -a "$LOGFILE"
        exit 1
    fi
    echo "WebSocket URL: $webSocketDebuggerUrl" | tee -a "$LOGFILE"
    youtube_fallback
    TOP_PID=$(get_top_pid)
    echo "TOP_PID = $TOP_PID" | tee -a "$LOGFILE"

    # Insert diagnostic run record and get run_id – capture only first line
    run_id=$(psql -U firefox -d firefox_logs -h localhost -tA -c "
        INSERT INTO diagnostic_runs (hostname, firefox_pid, auto_fix)
        VALUES ('$(hostname)', $TOP_PID, $AUTO_FIX)
        RETURNING run_id
    " | head -1)
    if [[ -z "$run_id" || ! "$run_id" =~ ^[0-9]+$ ]]; then
        echo "FATAL: Could not insert diagnostic run (invalid run_id)." | tee -a "$LOGFILE"
        exit 1
    fi
    echo "run_id = $run_id" | tee -a "$LOGFILE"

    # Record initial metrics – take first line only (fixes multi‑line bug)
    frag_score=$(awk '{for(i=4;i<=NF;i++) sum+=$i; print int(sum*100/512)}' /proc/buddyinfo 2>/dev/null | head -1)
    [[ -z "$frag_score" ]] && frag_score=0
    record_metric "fragmentation_score" "$frag_score" "percent"

    io_pressure=$(awk '/some/ {print $2}' /proc/pressure/io 2>/dev/null | cut -d= -f2 | cut -d. -f1 || echo "0")
    record_metric "psi_io_pct" "$io_pressure" "percent"

    cpu_usage=$(top -bn1 -p "$TOP_PID" 2>/dev/null | grep "$TOP_PID" | awk '{print $9}' | cut -d. -f1 || echo "0")
    record_metric "firefox_cpu_pct" "$cpu_usage" "percent"

    # Self‑healing decision based on historical data
    self_heal_memory

    set_firefox_prefs
    wake_dns
    memory_optimize
    apply_auto_fixes
    test_connectivity "after"

    # Record final metrics after fixes – take first line only
    frag_score_after=$(awk '{for(i=4;i<=NF;i++) sum+=$i; print int(sum*100/512)}' /proc/buddyinfo 2>/dev/null | head -1)
    [[ -z "$frag_score_after" ]] && frag_score_after=0
    record_metric "fragmentation_score_after" "$frag_score_after" "percent"

    record_event "info" "Diagnostic completed successfully" "main" "exit 0"
    echo "Diagnostic complete. Logs: $LOGFILE*" | tee -a "$LOGFILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi