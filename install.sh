#!/usr/bin/env bash
# PATH: install.sh
# ============================================================
# Observability Platform – Idempotent Installer
# Fixes vs previous version:
#   - Preflight checks: PostgreSQL running, initdb done, TimescaleDB loaded
#   - password_encryption=md5 SET before user CREATE/ALTER (same session)
#   - pg_hba.conf insertion uses fallback anchor when header comment absent
#   - glob-safe cp: skips missing file types instead of aborting
#   - pip + npm dependency installation added
#   - auto-remediate.timer presence verified before enable
#   - Final end-to-end validation query proves full stack
# ============================================================
set -euxo pipefail

# ============================================================
# PREFLIGHT CHECKS
# ============================================================
echo "=== Preflight Checks ==="

# 1. PostgreSQL must be installed
if ! command -v psql &>/dev/null; then
    echo "FATAL: psql not found. Run: sudo dnf install postgresql-server" >&2
    exit 1
fi

# 2. PostgreSQL service must be running
if ! sudo systemctl is-active --quiet postgresql; then
    echo "FATAL: PostgreSQL is not running."
    echo "  If first install: sudo postgresql-setup --initdb && sudo systemctl start postgresql" >&2
    exit 1
fi

# 3. pg_hba.conf must exist (proves initdb was run)
PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
if [[ ! -f "$PG_HBA" ]]; then
    echo "FATAL: $PG_HBA not found. Run: sudo postgresql-setup --initdb" >&2
    exit 1
fi

# 4. TimescaleDB must be in shared_preload_libraries
PG_CONF="/var/lib/pgsql/data/postgresql.conf"
if ! sudo grep -q 'timescaledb' "$PG_CONF" 2>/dev/null; then
    echo "FATAL: timescaledb not found in shared_preload_libraries in $PG_CONF" >&2
    echo "  Add: shared_preload_libraries = 'timescaledb'" >&2
    echo "  Then: sudo systemctl restart postgresql" >&2
    exit 1
fi

# 5. database/schema.sql must exist
if [[ ! -f "database/schema.sql" ]]; then
    echo "FATAL: database/schema.sql not found. Run from the repo root." >&2
    exit 1
fi

echo "✓ All preflight checks passed"
echo ""

# ============================================================
# DIRECTORY CREATION
# ============================================================
echo "=== Creating Directories ==="
sudo mkdir -pv /var/lib/observability/evidence
sudo mkdir -pv /var/lib/observability/repro_bundles
sudo mkdir -pv /var/lib/observability/config_snapshots
sudo mkdir -pv /var/log/observability
sudo mkdir -pv /etc/ssl/observability
sudo chown -R observer:observer /var/lib/observability
sudo chown -R observer:observer /var/log/observability
echo ""

# ============================================================
# OBSERVER OS USER – required by systemd User= directive
# Must exist as a Linux system account, not just a PostgreSQL role
# ============================================================
echo "=== Creating observer OS System Account ==="
if id observer &>/dev/null; then
    echo "✓ observer OS user already exists – skipping"
else
    sudo useradd --system --no-create-home --shell /sbin/nologin observer
    echo "✓ observer OS user created"
fi

# Re-apply ownership now that observer OS user definitely exists
sudo chown -R observer:observer /var/lib/observability
sudo chown -R observer:observer /var/log/observability
echo ""

# ============================================================
# DATABASE AND USER – IDEMPOTENT
# ============================================================
echo "=== Creating Database and User ==="

sudo -u postgres psql << 'PGSQL'
-- Force md5 password hashing for this session BEFORE any CREATE/ALTER USER
SET password_encryption = 'md5';

-- Create database idempotently
SELECT 'CREATE DATABASE observability OWNER postgres'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'observability'
)\gexec

-- Create or update observer user, always enforcing the password
-- so a pull on a fresh machine never silently skips password assignment
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_user WHERE usename = 'observer') THEN
        ALTER USER observer WITH PASSWORD 'observer';
        RAISE NOTICE 'observer user updated (password re-set)';
    ELSE
        CREATE USER observer WITH PASSWORD 'observer';
        RAISE NOTICE 'observer user created';
    END IF;
END
$$;
PGSQL

echo ""

# ============================================================
# SCHEMA
# ============================================================
echo "=== Applying Database Schema ==="
sudo -u postgres psql observability -f database/schema.sql
echo ""

# ============================================================
# pg_hba.conf – IDEMPOTENT AUTH RULES
# ============================================================
echo "=== Fixing PostgreSQL Authentication ==="
echo "Current rules (before):"
sudo grep -E '^(local|host)' "$PG_HBA" | head -12 || true

sudo cp -v "$PG_HBA" "${PG_HBA}.backup.$(date +%Y%m%d_%H%M%S)"

sudo python3 << 'PYSCRIPT'
import sys

HBA = "/var/lib/pgsql/data/pg_hba.conf"

with open(HBA, 'r') as f:
    original = f.readlines()

# Strip all existing observability/observer rules (non-comment lines)
cleaned = []
for line in original:
    stripped = line.strip()
    if stripped.startswith('#'):
        cleaned.append(line)
        continue
    if 'observability' in stripped and 'observer' in stripped:
        print(f"  Removed: {stripped}", file=sys.stderr, flush=True)
        continue
    cleaned.append(line)

# New rules to insert (md5 for local socket + IPv4 + IPv6)
NEW_RULES = [
    'local   observability   observer                                md5\n',
    'host    observability   observer    127.0.0.1/32            md5\n',
    'host    observability   observer    ::1/128                 md5\n',
]

# Try to insert after the "# TYPE  DATABASE" header line
# Fall back to inserting at the very top of the file if header not found
inserted = False
result = []
for line in cleaned:
    result.append(line)
    if not inserted and '# TYPE' in line and 'DATABASE' in line:
        result.extend(NEW_RULES)
        print("Added md5 auth rules after TYPE/DATABASE header", file=sys.stderr, flush=True)
        inserted = True

if not inserted:
    # Fallback: prepend rules before first non-comment, non-blank line
    fallback = []
    prepended = False
    for line in result:
        stripped = line.strip()
        if not prepended and stripped and not stripped.startswith('#'):
            fallback.extend(NEW_RULES)
            print("Added md5 auth rules (fallback: before first active rule)", file=sys.stderr, flush=True)
            prepended = True
        fallback.append(line)
    result = fallback

with open(HBA, 'w') as f:
    f.writelines(result)

print("pg_hba.conf written successfully", file=sys.stderr, flush=True)
PYSCRIPT

echo ""
echo "Rules (after):"
sudo grep -E '^(local|host)' "$PG_HBA" | head -12 || true

# ============================================================
# RESTART AND CONNECTION TEST
# ============================================================
echo ""
echo "=== Restarting PostgreSQL ==="
sudo systemctl restart postgresql
sleep 3
sudo systemctl status postgresql --no-pager -l

echo ""
echo "=== Testing Database Connection ==="
# Test via TCP (host=localhost → resolves both IPv4 127.0.0.1 and IPv6 ::1)
psql "dbname=observability user=observer password=observer host=127.0.0.1" -c "SELECT 1 AS tcp_ipv4_ok;"
psql "dbname=observability user=observer password=observer host=::1" -c "SELECT 1 AS tcp_ipv6_ok;"
# Test via Unix socket (local)
PGPASSWORD=observer psql -U observer -d observability -c "SELECT 1 AS unix_socket_ok;"

echo "✓ All connection tests passed"
echo ""

# ============================================================
# PYTHON DEPENDENCIES
# ============================================================
echo "=== Installing Python Dependencies ==="
if [[ -f "requirements.txt" ]]; then
    pip install --break-system-packages -r requirements.txt
else
    echo "WARNING: requirements.txt not found – skipping pip install" >&2
fi
echo ""

# ============================================================
# NODE DEPENDENCIES
# ============================================================
echo "=== Installing Node Dependencies ==="
if [[ -f "package.json" ]]; then
    npm install
else
    echo "WARNING: package.json not found – skipping npm install" >&2
fi
echo ""

# ============================================================
# COPY SCRIPTS – GLOB-SAFE (skips missing types instead of aborting)
# ============================================================
echo "=== Copying Scripts ==="
sudo mkdir -p /usr/local/bin

# Each glob is evaluated separately; shopt -s nullglob prevents abort on no match
shopt -s nullglob

SH_FILES=( scripts/*.sh )
PY_FILES=( scripts/*.py )
JS_FILES=( scripts/*.js )

if [[ ${#SH_FILES[@]} -gt 0 ]]; then
    sudo cp -v "${SH_FILES[@]}" /usr/local/bin/
    sudo chmod +x "${SH_FILES[@]/#scripts\//\/usr\/local\/bin\/}"
else
    echo "WARNING: no .sh files in scripts/ – skipping" >&2
fi

if [[ ${#PY_FILES[@]} -gt 0 ]]; then
    sudo cp -v "${PY_FILES[@]}" /usr/local/bin/
    sudo chmod +x "${PY_FILES[@]/#scripts\//\/usr\/local\/bin\/}"
else
    echo "WARNING: no .py files in scripts/ – skipping" >&2
fi

if [[ ${#JS_FILES[@]} -gt 0 ]]; then
    sudo cp -v "${JS_FILES[@]}" /usr/local/bin/
    sudo chmod +x "${JS_FILES[@]/#scripts\//\/usr\/local\/bin\/}"
else
    echo "WARNING: no .js files in scripts/ – skipping" >&2
fi

shopt -u nullglob
echo ""

# ============================================================
# SYSTEMD UNITS
# ============================================================
echo "=== Installing Systemd Units ==="

shopt -s nullglob
SVC_FILES=( systemd/*.service )
TIMER_FILES=( systemd/*.timer )
shopt -u nullglob

if [[ ${#SVC_FILES[@]} -gt 0 ]]; then
    sudo cp -v "${SVC_FILES[@]}" /etc/systemd/system/
else
    echo "WARNING: no .service files in systemd/ – skipping" >&2
fi

if [[ ${#TIMER_FILES[@]} -gt 0 ]]; then
    sudo cp -v "${TIMER_FILES[@]}" /etc/systemd/system/
else
    echo "WARNING: no .timer files in systemd/ – skipping" >&2
fi

sudo systemctl daemon-reload
echo ""

# ============================================================
# ENABLE SERVICES – each checked for existence before enable
# ============================================================
echo "=== Enabling Services ==="

enable_if_exists() {
    local unit="$1"
    if [[ -f "/etc/systemd/system/${unit}" ]]; then
        sudo systemctl enable "$unit"
        echo "✓ Enabled: $unit"
    else
        echo "WARNING: $unit not found in /etc/systemd/system/ – skipping enable" >&2
    fi
}

enable_if_exists journal-ingester.service
enable_if_exists psi-collector.timer
enable_if_exists firefox-gpu-monitor.timer
enable_if_exists auto-remediate.timer
enable_if_exists websocket-broker.service
enable_if_exists dead-letter-replay.timer
enable_if_exists validate-observability.timer

echo ""

# ============================================================
# FINAL END-TO-END VALIDATION
# ============================================================
echo "=== Final Validation ==="

# Prove schema is live
PGPASSWORD=observer psql -U observer -d observability -h 127.0.0.1 -c \
    "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"

# Prove TimescaleDB hypertable is registered
PGPASSWORD=observer psql -U observer -d observability -h 127.0.0.1 -c \
    "SELECT hypertable_name, num_chunks FROM timescaledb_information.hypertables;"

echo ""
echo "✓✓✓ Installation complete ✓✓✓"
echo ""
echo "Start services:"
echo "  sudo systemctl start journal-ingester psi-collector.timer firefox-gpu-monitor.timer"
echo ""
echo "Verify live ingestion (after start):"
echo "  PGPASSWORD=observer psql -U observer -d observability -h 127.0.0.1 \\"
echo "    -c \"SELECT COUNT(*) FROM events WHERE time > NOW() - INTERVAL '1 minute';\""