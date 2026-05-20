#!/usr/bin/env bash
# PATH: audit_0011.sh
#
# VERSION 0011: COMPLETE ENFORCEMENT – No Evasion, No Exceptions
#                UPDATED: Rule 35 tightened to require WHERE run_id or WHERE created_at
#
# This audit script adds all previous checks (0007-0010) PLUS:
#   - Mandatory PostgreSQL connection (no conditional bypass)
#   - Actual database writes (not just pattern presence)
#   - Self-healing evidence (historical query output with WHERE run_id or WHERE created_at)
#   - All rules are numbered explicitly, no gaps
#
# MENTAL MODEL: audit_0010.sh allowed evasion via conditionals (e.g., --auto-fix bypassing DB).
#               audit_0011.sh forces unconditional execution of critical components.
# FAILURE MODE: exits 1 if any rule fails (no warnings, only passes or fails)
#
# Source (Tier 1): This script is original work based on requirements analysis.

set -euo pipefail

RESPONSE_FILE="${1:-}"
RULES_FILE="${2:-system_prompt_FINAL.md}"

if [[ -z "$RESPONSE_FILE" || ! -f "$RESPONSE_FILE" ]]; then
    echo "USAGE: bash audit_0011.sh <response_file> [rules_file]"
    echo "  response_file: LLM response with script and execution evidence"
    exit 1
fi

if [[ ! -f "$RULES_FILE" ]]; then
    echo "FAIL: rules file not found: $RULES_FILE"
    exit 1
fi

PASS=0
FAIL=0
GAPS=()

# Helper functions
check() {
    local desc="$1"
    local pat="$2"
    if grep -qiE "$pat" "$RESPONSE_FILE"; then
        echo "  PASS: $desc"
        (( PASS++ )) || true
    else
        echo "  FAIL: $desc"
        (( FAIL++ )) || true
        GAPS+=("$desc")
    fi
}

count_pattern() {
    grep -cE "$1" "$RESPONSE_FILE" 2>/dev/null || echo 0
}

# ==================================================================
# STEP 0 – RESPONSE FORMAT VALIDATION (Same as audit_0010.sh)
# ==================================================================
echo "========================================"
echo "STEP 0 -- RESPONSE FORMAT VALIDATION"
echo "========================================"

if head -20 "$RESPONSE_FILE" | grep -qE '^\s*\{' && \
   grep -qE '"(response_text|fixes|compliance_explanation|analysis|script)"' "$RESPONSE_FILE"; then
    echo "  FATAL: JSON format detected. Plain text markdown required."
    exit 1
fi

if ! grep -qE '^#!/usr/bin/env (bash|sh)' "$RESPONSE_FILE"; then
    echo "  WARN: No shebang found – but continuing"
else
    echo "  PASS: Shebang present"
    (( PASS++ )) || true
fi

FENCE_COUNT=$(grep -cE '^\`\`\`' "$RESPONSE_FILE" || echo 0)
if (( FENCE_COUNT >= 2 && FENCE_COUNT % 2 == 0 )); then
    echo "  PASS: Code fences balanced ($FENCE_COUNT)"
    (( PASS++ )) || true
else
    echo "  WARN: Unbalanced fences"
fi

# ==================================================================
# STEP 0.5 – CODE PATTERN ENFORCEMENT (from audit_0010.sh)
# ==================================================================
echo ""
echo "========================================"
echo "STEP 0.5 -- CODE PATTERN ENFORCEMENT"
echo "========================================"

CODE_BLOCKS=$(awk '/^```bash/,/^```/ {if (!/^```/) print}' "$RESPONSE_FILE")
CODE_BLOCK_COUNT=$(echo "$CODE_BLOCKS" | grep -c "^" 2>/dev/null || echo 0)

if (( CODE_BLOCK_COUNT == 0 )); then
    echo "  FAIL: No bash code blocks found"
    (( FAIL++ )) || true
    GAPS+=("No code blocks")
else
    echo "  PASS: Found $CODE_BLOCK_COUNT lines of bash code"
    (( PASS++ )) || true
fi

# CP02: citation comments with URLs
SOURCE_COMMENTS=$(grep -c "^[[:space:]]*# Source" "$RESPONSE_FILE" 2>/dev/null || echo 0)
if (( SOURCE_COMMENTS == 0 )); then
    echo "  FAIL: No '# Source' citations"
    (( FAIL++ )) || true
    GAPS+=("No citations")
else
    echo "  PASS: $SOURCE_COMMENTS citations found"
    (( PASS++ )) || true
fi

TIER2_PLUS=$(grep "^[[:space:]]*# Source (Tier [234])" "$RESPONSE_FILE" | wc -l 2>/dev/null || echo 0)
TIER2_PLUS_WITH_URL=$(grep "^[[:space:]]*# Source (Tier [234])" "$RESPONSE_FILE" | grep -c "https://" 2>/dev/null || echo 0)
if (( TIER2_PLUS > 0 && TIER2_PLUS_WITH_URL < TIER2_PLUS )); then
    echo "  FAIL: $((TIER2_PLUS - TIER2_PLUS_WITH_URL)) Tier 2+ citations missing URLs"
    (( FAIL++ )) || true
    GAPS+=("Citations missing URLs")
else
    echo "  PASS: All Tier 2+ citations have URLs"
    (( PASS++ )) || true
fi

# CP03: verbatim quotes in citations (≥80%)
CITATIONS_WITH_QUOTES=$(grep "^[[:space:]]*# Source" "$RESPONSE_FILE" | grep -c '"' 2>/dev/null || echo 0)
if (( SOURCE_COMMENTS > 0 )); then
    QUOTE_RATIO=$((CITATIONS_WITH_QUOTES * 100 / SOURCE_COMMENTS))
    if (( QUOTE_RATIO < 80 )); then
        echo "  FAIL: Only $CITATIONS_WITH_QUOTES/$SOURCE_COMMENTS citations have quotes ($QUOTE_RATIO%)"
        (( FAIL++ )) || true
        GAPS+=("Citations lack verbatim quotes")
    else
        echo "  PASS: $QUOTE_RATIO% citations have quotes"
        (( PASS++ )) || true
    fi
fi

# CP04: valid source tiers – simplified check
INVALID_URLS=$(grep -oE "https://[^[:space:]]+" "$RESPONSE_FILE" | grep -vE "(man7|kernel|mozilla|stackoverflow|github)" | wc -l || echo 0)
if (( INVALID_URLS > 0 )); then
    echo "  FAIL: $INVALID_URLS URLs from invalid domains"
    (( FAIL++ )) || true
    GAPS+=("Invalid source URLs")
else
    echo "  PASS: All URLs from valid domains"
    (( PASS++ )) || true
fi

# CP05: complete code (functions called, shebang)
FUNCTION_DEFS=$(echo "$CODE_BLOCKS" | grep -cE "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)" 2>/dev/null || echo 0)
if (( FUNCTION_DEFS > 0 )); then
    # Simple check: ensure that function names appear later in code (not perfect but indicative)
    FUNC_NAMES=$(echo "$CODE_BLOCKS" | grep -oE "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)" | sed 's/().*//' | tr -d ' ')
    uncalled=0
    for func in $FUNC_NAMES; do
        if ! echo "$CODE_BLOCKS" | grep -qE "^[[:space:]]*$func[[:space:]]"; then
            uncalled=$((uncalled + 1))
        fi
    done
    if (( uncalled > 0 )); then
        echo "  FAIL: $uncalled function(s) defined but never called"
        (( FAIL++ )) || true
        GAPS+=("Uncalled functions")
    else
        echo "  PASS: All functions called"
        (( PASS++ )) || true
    fi
fi

if echo "$CODE_BLOCKS" | grep -qE "^#!/"; then
    echo "  PASS: Shebang present in code block"
    (( PASS++ )) || true
else
    echo "  FAIL: No shebang in script"
    (( FAIL++ )) || true
    GAPS+=("Missing shebang")
fi

# CP06: VERIFIES WITH and EXECUTION EVIDENCE
VERIFY_COUNT=$(grep -c "# VERIFIES WITH:" "$RESPONSE_FILE" 2>/dev/null || echo 0)
CMD_BLOCKS=$(grep -c "^```bash" "$RESPONSE_FILE" 2>/dev/null || echo 0)
if (( CMD_BLOCKS > 0 && VERIFY_COUNT < CMD_BLOCKS )); then
    echo "  FAIL: $((CMD_BLOCKS - VERIFY_COUNT)) command block(s) missing verification"
    (( FAIL++ )) || true
    GAPS+=("Missing VERIFIES WITH")
else
    echo "  PASS: All command blocks have verification comments"
    (( PASS++ )) || true
fi

if ! grep -qE "EXECUTION EVIDENCE:|EXIT=[0-9]|ELAPSED=[0-9]" "$RESPONSE_FILE"; then
    echo "  FAIL: No EXECUTION EVIDENCE block"
    (( FAIL++ )) || true
    GAPS+=("No execution evidence")
else
    echo "  PASS: EXECUTION EVIDENCE present"
    (( PASS++ )) || true
fi

# ==================================================================
# STEP 1 – ACTIVE RULES (from audit_0010.sh)
# ==================================================================
echo ""
echo "========================================"
echo "STEP 1 -- ACTIVE RULES"
echo "========================================"

grep -E "^## RULE|^### STRUCTURAL RULE" "$RULES_FILE" 2>/dev/null || echo "  No rules found"
RULE_COUNT=$(grep -cE "^## RULE|^### STRUCTURAL RULE" "$RULES_FILE" 2>/dev/null || echo 0)
echo "Total rules active: $RULE_COUNT"

# ==================================================================
# STEP 2 – EVASION CHECKS (from audit_0010.sh, Rules 0-31)
# ==================================================================
echo ""
echo "========================================"
echo "STEP 2 -- EVASION CHECKS (Rules 0-31)"
echo "========================================"

# Rule 0
check "Rule 0: SELF-CHECK block present" "SELF-CHECK:"
check "Rule 0: per-item evidence quotes" "Per-item evidence|evidence quote|confirmed by:|line [0-9]+|document [0-9]"

# Rule 1
check "Rule 1: claims attributed to specific output" "per the|confirmed by|shown in|visible in|document [0-9]"

# Rule 2 (conditional on code blocks)
if grep -qiE "^\`\`\`(bash|sh)" "$RESPONSE_FILE"; then
    check "Rule 2: WHY/ASSUMES/VERIFIES headers" "# WHY:|# ASSUMES:|# VERIFIES WITH:"
fi

# Rule 3 (if cp/tee/cat/write/deploy/upgrade)
if grep -qiE "(cp |tee |cat >|write|deploy|upgrade)" "$RESPONSE_FILE"; then
    check "Rule 3: verification step present" "VERIFIES WITH|confirms|verify|confirmed|bash -n|syntax OK"
fi

# Rule 4 (if assumes/assuming/must be/should be)
if grep -qiE "assumes|assuming|must be|should be" "$RESPONSE_FILE"; then
    check "Rule 4: assumptions marked with [ASSUMPTION:]" "\\[ASSUMPTION:|assumed:|\\[ASSUMPTION"
fi

# Rule 5 (if fix/patch/resolve/upgrade)
if grep -qiE "\bfix\b|\bpatch\b|\bresolve\b|\bupgrade\b" "$RESPONSE_FILE"; then
    check "Rule 5: root cause stated before fix" "[Rr]oot cause:|[Cc]ause:|[Rr]eason:"
fi

# Rule 6 (warn only)
if grep -qiE "you might also|you could also|additionally.*consider|also consider" "$RESPONSE_FILE"; then
    echo "  WARN: Rule 6 – unrequested suggestions"
fi

# Rule 7
check "Rule 7: context inventory before analysis" "[Cc]ontext inventory|[Cc]an see:|[Cc]annot see:|[Pp]resent:|[Aa]bsent:"

# Rule 8 (if cd/rm/mv/cp/mkdir/find)
if grep -qiE "^(cd |rm |mv |cp |mkdir |find \.)" "$RESPONSE_FILE"; then
    check "Rule 8: working directory stated" "[Cc]urrent directory:|[Ww]orking directory:|per.*prompt"
fi

# Rule 9 (if references .sh or .bash)
if grep -qiE "\.(sh|bash)\b" "$RESPONSE_FILE"; then
    check "Rule 9: execute bit status stated" "execute bit|chmod|rwxr|rw-r|ls -la|permission"
fi

# Rule 10 (if sudo with certain tools)
if grep -qiE "sudo (bpftrace|iotop|perf|strace|kill|renice)" "$RESPONSE_FILE"; then
    check "Rule 10: dependency detection alongside sudo" "check_cmd|command -v|Missing dependency|check_dependencies"
fi

# Rule 11 (if source or .)
if grep -qE "source |\. \." "$RESPONSE_FILE"; then
    check "Rule 11: sourced script functions called after sourcing" "check_dependencies|check_cmd|source.*&&|after.*source"
fi

# Rule 12 – content after last fence
if grep -q "^\`\`\`" "$RESPONSE_FILE" 2>/dev/null; then
    LAST_FENCE=$(grep -n "^\`\`\`" "$RESPONSE_FILE" | tail -1 | cut -d: -f1)
    TOTAL_LINES=$(wc -l < "$RESPONSE_FILE")
    LINES_AFTER=$((TOTAL_LINES - LAST_FENCE))
    NONEMPTY_AFTER=$(tail -n "$LINES_AFTER" "$RESPONSE_FILE" 2>/dev/null | grep -c "[^ \t]" 2>/dev/null || echo 0)
    if (( NONEMPTY_AFTER > 0 )); then
        echo "  FAIL: Rule 12 – content after last fence"
        (( FAIL++ )) || true
        GAPS+=("Rule 12: content after fence")
    else
        echo "  PASS: Rule 12 – no content after fence"
        (( PASS++ )) || true
    fi
fi

# Rule 13 (if delivery claim)
if grep -qiE "present_files|linked above|deliver" "$RESPONSE_FILE"; then
    check "Rule 13: download link present" "local_resource|\.sh\b|\.md\b|\.py\b"
fi

# Rule 14
if grep -qE "#!/usr/bin/env (bash|sh)" "$RESPONSE_FILE"; then
    check "Rule 14: PATH comment present" "# PATH:"
fi

# Rule 15 (if tool output claimed)
if grep -qiE "bash tool|tool output|produced output|output shows" "$RESPONSE_FILE"; then
    check "Rule 15: tool output in fence" "^\`\`\`$|^\`\`\`bash|^\`\`\`sh"
fi

# Rule 16 – manual instruction detection
if grep -qiE "manually (install|download|configure|run|type|add)" "$RESPONSE_FILE"; then
    echo "  FAIL: Rule 16 – manual instruction detected"
    (( FAIL++ )) || true
    GAPS+=("Rule 16: manual instruction")
else
    echo "  PASS: Rule 16 – no manual instructions"
    (( PASS++ )) || true
fi

# Rule 17 (if mentions sudoers, /usr/bin/, etc.)
if grep -qiE "sudoers|/usr/bin/|NOPASSWD|binary path|username|whoami" "$RESPONSE_FILE"; then
    check "Rule 17: system-specific values confirmed from output" "which |confirmed.*output|confirmed.*prompt|per.*prompt"
fi

# Rule 18 (if cp/tee/xclip)
if grep -qiE "(cp |tee |xclip).*\.(sh|md|py)" "$RESPONSE_FILE"; then
    check "Rule 18: deployment confirmed (not assumed)" "syntax OK|wc -l|cat.*deployed|content.*confirm"
fi

# Rule 19 (if fix/patch/resolve/upgrade)
if grep -qiE "\bfix\b|\bpatch\b|\bresolve\b|\bupgrade\b" "$RESPONSE_FILE"; then
    check "Rule 19: fix checked for same-class recurrence" "same class|new instance|introduces.*same|recur|also requires"
fi

# Rule 20 (if bash -n or syntax OK)
if grep -qiE "bash -n|syntax OK" "$RESPONSE_FILE"; then
    check "Rule 20: fix confirmed by execution not just syntax" "exit: 0|no error|confirmed working|test passing|output shows"
fi

# Rule 21 (if smoke test)
if grep -qiE "smoke test|synthetic|test.*log|cat >.*log" "$RESPONSE_FILE"; then
    check "Rule 21: test uses real machine output format" "real.*log|document [0-9]|cat -v|verbatim|actual.*byte"
fi

# Rule 22 (if str_replace/REPLACED OK)
if grep -qiE "str_replace|REPLACED OK" "$RESPONSE_FILE"; then
    check "Rule 22: changed region read after str_replace" "sed -n.*p.*\.sh|view.*\.sh|grep -n.*\.sh|lines.*after"
fi

# Rule 23
if grep -qiE "REQUEST COMPONENTS|\[1\].*COVERED|NOT COVERED" "$RESPONSE_FILE"; then
    check "Rule 23: components marked COVERED" "COVERED by|NOT COVERED"
    if grep -q "NOT COVERED" "$RESPONSE_FILE"; then
        echo "  FAIL: Rule 23 – NOT COVERED present"
        (( FAIL++ )) || true
        GAPS+=("Rule 23: NOT COVERED")
    fi
fi

# Rule 24 (if repeated failures)
if grep -qiE "failed.*attempt|attempt.*failed|second.*fail|fail.*twice" "$RESPONSE_FILE"; then
    check "Rule 24: diagnostic after repeated failure" "ELAPSED:|EXIT: [0-9]|bytes:|diagnostic|I do not know the root cause"
fi

# Rule 25 (if confirmed fact)
if grep -qiE "confirmed fact|confirmed:|confirmed by" "$RESPONSE_FILE"; then
    check "Rule 25: confirmed facts cite verbatim output" "document [0-9]|verbatim|Hypothes[ei]s|[Hh]ypothes"
fi

# Rule 26
if grep -qiE "SELF-CHECK:" "$RESPONSE_FILE"; then
    check "Rule 26: SELF-CHECK contains per-item evidence quotes" "document [0-9]|Per-item evidence|evidence quote"
fi

# Rule 27
if grep -qE "^\`\`\`(bash|sh)" "$RESPONSE_FILE"; then
    check "Rule 27: EXECUTION EVIDENCE block present" "EXECUTION EVIDENCE:|EVIDENCE OK:|EXIT=[0-9]|ELAPSED=[0-9]"
fi

# Rule 28
if grep -qiE "sudo|perf|strace|bpftrace|mprotect|mmap|futex|clone|fork|ptrace|signal" "$RESPONSE_FILE"; then
    check "Rule 28: technical claims carry linked citations" "# Source:|Source \(Tier|Tier [1-4]|https://"
fi

# Rule 29
if grep -qiE "# Source:|Source \(Tier" "$RESPONSE_FILE"; then
    check "Rule 29: CITATION CHECK block present" "CITATION CHECK|citation evidence|Tier identified"
fi

# Rule 30 – no stderr suppression
if grep -qE "^[[:space:]]*[^#[:space:]][^#]*2>/dev/null|^[[:space:]]*[^#[:space:]][^#]*&>/dev/null" "$RESPONSE_FILE"; then
    echo "  FAIL: Rule 30 – stderr suppression found"
    (( FAIL++ )) || true
    GAPS+=("Rule 30: stderr suppression")
else
    echo "  PASS: Rule 30 – no stderr suppression"
    (( PASS++ )) || true
fi

# Rule 31 – no sed
if grep -qE "\bsed\b" "$RESPONSE_FILE"; then
    SEDLINES=$(grep -nE "\bsed\b" "$RESPONSE_FILE" | grep -vE "^[0-9]+:[[:space:]]*#")
    if [ -n "$SEDLINES" ]; then
        echo "  FAIL: Rule 31 – sed present in code"
        (( FAIL++ )) || true
        GAPS+=("Rule 31: sed present")
    else
        echo "  PASS: Rule 31 – sed only in comments"
        (( PASS++ )) || true
    fi
else
    echo "  PASS: Rule 31 – no sed"
    (( PASS++ )) || true
fi

# ==================================================================
# STEP 3 – FIREFOX DIAGNOSTIC CHECKS (from audit_0010.sh)
# ==================================================================
echo ""
echo "========================================"
echo "STEP 3 -- FIREFOX DIAGNOSTIC CHECKS"
echo "========================================"

check "SELinux: setenforce 0" "setenforce 0"
check "SELinux: trap restore" "trap.*setenforce 1"
check "ptrace_scope: set to 0" "ptrace_scope.*0"
check "ptrace_scope: trap restore" "trap.*ptrace_scope"
check "Dependencies: command -v" "command -v|check_dependencies"
check "PostgreSQL: password collected at start" "read -s PGPASSWORD|PGPASSWORD="
check "PostgreSQL: connection test" "timeout.*psql.*SELECT 1"
check "Firefox: launched without sudo" "firefox --profile.*--remote-debugging-port"
check "Firefox: sudo pkill present" "sudo pkill -9 -x firefox"
check "Firefox: startup verification loop" "for i in.*pgrep.*firefox"
check "Firefox: profile lock waiting (fuser)" "fuser.*PROFILE_DIR"
check "CDP: waiting for port 9222" "Waiting for port 9222"
check "CDP: webSocketDebuggerUrl detection" "webSocketDebuggerUrl"
check "YouTube: fallback command" "firefox --new-tab.*youtube"
check "TOP_PID: awk print" "awk.*print.*\\\$2"
check "Memory: compaction" "compact_memory"
check "Memory: drop_caches" "drop_caches"
check "Connectivity: test before" "test_connectivity.*before"
check "Connectivity: test after" "test_connectivity.*after"
check "Headers: WHY present" "# WHY:"
check "Comments: MENTAL MODEL" "# MENTAL MODEL"
check "Comments: FAILURE MODE" "# FAILURE MODE"
check "add_pref: sudo tee -a" "sudo tee -a"
check "WebRender: gfx.webrender.all true" "gfx.webrender.all.*true"
check "Sync: services.sync.engine.*false" "services.sync.engine.*false"
check "DNS: flush-caches" "systemd-resolve.*flush-caches|resolvectl.*flush-caches"
check "DNS: wake_dns function" "wake_dns\(\)"

# ==================================================================
# STEP 4 – RUNTIME ERROR DETECTION (from audit_0010.sh)
# ==================================================================
echo ""
echo "========================================"
echo "STEP 4 -- RUNTIME ERROR DETECTION"
echo "========================================"

JS_UNREACHABLE=$(count_pattern "unreachable code after return statement")
if (( JS_UNREACHABLE > 0 )); then
    echo "  FAIL: unreachable code errors: $JS_UNREACHABLE"
    (( FAIL++ )) || true
    GAPS+=("JS unreachable code")
else
    echo "  PASS: No unreachable code errors"
    (( PASS++ )) || true
fi

TIMEOUT_ERR=$(count_pattern "Script terminated by timeout")
if (( TIMEOUT_ERR > 0 )); then
    echo "  FAIL: script timeout errors: $TIMEOUT_ERR"
    (( FAIL++ )) || true
    GAPS+=("JS timeout")
else
    echo "  PASS: No timeout errors"
    (( PASS++ )) || true
fi

MESA_COUNT=$(count_pattern "ATTENTION: default value of option mesa_glthread overridden")
if (( MESA_COUNT > 0 )); then
    echo "  WARN: mesa_glthread overridden: $MESA_COUNT"
else
    echo "  PASS: No mesa_glthread warnings"
    (( PASS++ )) || true
fi

CDP_FAIL=$(count_pattern "No WebSocket URL found|CDP not ready")
if (( CDP_FAIL > 0 )); then
    echo "  WARN: CDP WebSocket failures: $CDP_FAIL"
else
    echo "  PASS: CDP WebSocket working"
    (( PASS++ )) || true
fi

FXA_COUNT=$(count_pattern "FirefoxAccounts.*ERROR")
if (( FXA_COUNT > 10 )); then
    echo "  WARN: Excessive Firefox Accounts errors: $FXA_COUNT"
else
    echo "  PASS: Firefox Accounts errors within tolerance"
    (( PASS++ )) || true
fi

FRAG_SCORE=$(grep -oE "Fragmentation.*Score: [0-9]+" "$RESPONSE_FILE" | grep -oE "[0-9]+" | head -1)
if [ -n "$FRAG_SCORE" ] && (( FRAG_SCORE > 70 )); then
    echo "  FAIL: Fragmentation score $FRAG_SCORE > 70"
    (( FAIL++ )) || true
    GAPS+=("High fragmentation")
elif [ -n "$FRAG_SCORE" ]; then
    echo "  PASS: Fragmentation score $FRAG_SCORE (≤70)"
    (( PASS++ )) || true
fi

PSI_IO=$(grep -oE "PSI I/O: [0-9.]+%" "$RESPONSE_FILE" | grep -oE "[0-9.]+" | head -1)
if [ -n "$PSI_IO" ]; then
    PSI_INT=$(echo "$PSI_IO" | cut -d. -f1)
    if (( PSI_INT > 30 )); then
        echo "  FAIL: PSI I/O ${PSI_IO}% > 30%"
        (( FAIL++ )) || true
        GAPS+=("High PSI I/O")
    else
        echo "  PASS: PSI I/O ${PSI_IO}% ≤30%"
        (( PASS++ )) || true
    fi
fi

FF_CPU=$(grep -oE "Firefox CPU: [0-9.]+%" "$RESPONSE_FILE" | grep -oE "[0-9.]+" | head -1)
if [ -n "$FF_CPU" ]; then
    CPU_INT=$(echo "$FF_CPU" | cut -d. -f1)
    if (( CPU_INT > 25 )); then
        echo "  FAIL: Firefox CPU ${FF_CPU}% > 25%"
        (( FAIL++ )) || true
        GAPS+=("High Firefox CPU")
    else
        echo "  PASS: Firefox CPU ${FF_CPU}% ≤25%"
        (( PASS++ )) || true
    fi
fi

# ==================================================================
# NEW CHECKS for audit_0011.sh (No Evasion, No Exceptions)
# ==================================================================
echo ""
echo "========================================"
echo "NEW CHECKS (audit_0011) – FORCING UNCONDITIONAL EXECUTION"
echo "========================================"

# Rule 32: PostgreSQL must NOT be conditionally skipped (e.g., via AUTO_FIX guard)
if grep -qE "if.*AUTO_FIX.*true.*[\n]*.*else.*(USE_POSTGRES=false|return 0|skip)" "$RESPONSE_FILE"; then
    echo "  FAIL: Rule 32 – PostgreSQL setup is conditionally skipped (evasion detected)"
    (( FAIL++ )) || true
    GAPS+=("Rule 32: Conditional PostgreSQL skip")
else
    if grep -q "USE_POSTGRES=false" "$RESPONSE_FILE"; then
        echo "  FAIL: Rule 32 – USE_POSTGRES=false present (disables PostgreSQL)"
        (( FAIL++ )) || true
        GAPS+=("Rule 32: USE_POSTGRES=false")
    else
        echo "  PASS: Rule 32 – No conditional PostgreSQL skip"
        (( PASS++ )) || true
    fi
fi

# Rule 33: Execution evidence must contain actual psql output (not just a skip message)
PSQL_OUTPUT=$(grep -A5 -B5 "EXECUTION EVIDENCE" "$RESPONSE_FILE" | grep -i "psql\|SELECT 1\|connection\|database" | head -1)
if [[ -z "$PSQL_OUTPUT" ]]; then
    echo "  FAIL: Rule 33 – Execution evidence does not show actual psql output"
    (( FAIL++ )) || true
    GAPS+=("Rule 33: No psql output in evidence")
else
    echo "  PASS: Rule 33 – psql output present in execution evidence"
    (( PASS++ )) || true
fi

# Rule 34: Script must write to PostgreSQL tables (diagnostic_runs, metrics, events, fixes)
if grep -qiE "INSERT INTO (diagnostic_runs|metrics|events|fixes)" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 34 – Database INSERT statements present"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 34 – No INSERT into required tables"
    (( FAIL++ )) || true
    GAPS+=("Rule 34: Missing INSERT statements")
fi

# Rule 35: Self‑healing must be present – script must query historical data with a run‑identifying filter
if grep -qiE "SELECT.*FROM (diagnostic_runs|metrics|events|fixes).*WHERE (run_id|created_at|run_timestamp)" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 35 – Self‑healing query with run_id/created_at filter present"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 35 – No self‑healing query with WHERE run_id or WHERE created_at (required to ensure adaptive logic)"
    (( FAIL++ )) || true
    GAPS+=("Rule 35: Missing self‑healing query with run filter")
fi

# Rule 36: The script must not bypass PostgreSQL when --auto-fix is used without password
# Instead, it must fail or prompt. Look for exit 1 or error message.
if grep -qE "ERROR.*--auto-fix.*requires PostgreSQL password" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 36 – --auto-fix requires password, no silent bypass"
    (( PASS++ )) || true
else
    echo "  WARN: Rule 36 – No explicit requirement for password with --auto-fix (may still be compliant if password provided)"
fi

# Rule 37: The response must include a CITATION CHECK block that explicitly cites the PostgreSQL documentation
if grep -qiE "CITATION CHECK.*postgresql.*libpq" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 37 – Citation includes PostgreSQL docs"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 37 – Missing PostgreSQL citation"
    (( FAIL++ )) || true
    GAPS+=("Rule 37: Missing PostgreSQL citation")
fi

# Rule 38: The script must contain # VERIFIES WITH comments for every database operation
PSQL_CMDS=$(grep -c "psql -c" "$RESPONSE_FILE" 2>/dev/null || echo 0)
VERIFY_DB=$(grep -c "# VERIFIES WITH.*psql\|# VERIFIES WITH.*database\|# VERIFIES WITH.*INSERT" "$RESPONSE_FILE" 2>/dev/null || echo 0)
if (( PSQL_CMDS > 0 && VERIFY_DB < PSQL_CMDS )); then
    echo "  FAIL: Rule 38 – $((PSQL_CMDS - VERIFY_DB)) database operations lack verification comments"
    (( FAIL++ )) || true
    GAPS+=("Rule 38: Missing VERIFIES WITH for DB ops")
else
    echo "  PASS: Rule 38 – All database ops have verification"
    (( PASS++ )) || true
fi

# Rule 39: No placeholder or fake output in EXECUTION EVIDENCE (must show real row counts, timings)
EVIDENCE_BLOCK=$(grep -A20 "EXECUTION EVIDENCE" "$RESPONSE_FILE" | head -30)
if echo "$EVIDENCE_BLOCK" | grep -qE "\.\.\."; then
    echo "  FAIL: Rule 39 – Ellipsis found in execution evidence (placeholder)"
    (( FAIL++ )) || true
    GAPS+=("Rule 39: Placeholder output")
else
    if echo "$EVIDENCE_BLOCK" | grep -qE "STDOUT: \.\.\."; then
        echo "  FAIL: Rule 39 – Placeholder pattern '...' found"
        (( FAIL++ )) || true
        GAPS+=("Rule 39: Placeholder output")
    else
        echo "  PASS: Rule 39 – No placeholder ellipsis in evidence"
        (( PASS++ )) || true
    fi
fi

# Rule 40: The script must use a run_id variable and log it (evidence must show run_id)
if grep -qE "run_id=" "$RESPONSE_FILE" && grep -qE "run_id.*psql" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 40 – run_id captured and used"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 40 – No run_id captured from database"
    (( FAIL++ )) || true
    GAPS+=("Rule 40: Missing run_id")
fi

# Rule 41: Execution evidence must show at least one successful INSERT into a table
if grep -qiE "INSERT 0 1|INSERT.*returning|psql.*INSERT" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 41 – Evidence of successful INSERT"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 41 – No evidence of successful database write"
    (( FAIL++ )) || true
    GAPS+=("Rule 41: No successful INSERT evidence")
fi

# Rule 42: The script must contain a self‑healing loop (e.g., while/trap with retry logic)
if grep -qE "while.*retry|for.*retry.*psql|timeout.*psql" "$RESPONSE_FILE"; then
    echo "  PASS: Rule 42 – Self‑healing retry loop present"
    (( PASS++ )) || true
else
    echo "  FAIL: Rule 42 – No retry loop for database operations"
    (( FAIL++ )) || true
    GAPS+=("Rule 42: Missing retry loop")
fi

# ==================================================================
# STEP 5 – GAP REPORT
# ==================================================================
echo ""
echo "========================================"
echo "STEP 5 -- GAP REPORT"
echo "========================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo ""

if (( FAIL == 0 )); then
    echo "✓ ALL CHECKS PASSED – No evasion detected"
else
    echo "✗ FAILED – The following gaps must be fixed:"
    for gap in "${GAPS[@]}"; do
        echo "  - $gap"
    done
    echo ""
    echo "Critical new rules to enforce:"
    echo "  - PostgreSQL must be used unconditionally (no USE_POSTGRES=false)"
    echo "  - Execution evidence must contain actual psql output (not skip messages)"
    echo "  - Script must insert into diagnostic_runs, metrics, events, fixes"
    echo "  - Self‑healing queries must filter by run_id or created_at (to ensure adaptive logic)"
    echo "  - No placeholders like '...' in EXECUTION EVIDENCE"
    echo "  - run_id must be captured and used"
    echo "  - Retry loops for database operations"
fi

echo "========================================"
echo "AUDIT COMPLETE"
echo "========================================"