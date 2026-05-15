#!/usr/bin/env bash
# PATH: bootstrap.sh
#
# WHAT: Complete setup script for observability platform on fresh Fedora machine
# WHY:  Automates all dependencies, database setup, and service deployment
#       with maximum verbosity - every command visible, no output hidden
#
# MENTAL MODEL BEFORE: fresh Fedora machine, git repo cloned
# MENTAL MODEL AFTER:  PostgreSQL + TimescaleDB running, all services active,
#                      logs flowing to /var/log/observability/
#
# FAILURE MODE: if PostgreSQL already initialized, postgresql-setup errors
#               (harmless - continues); if services already running, systemctl
#               start shows "already active" (also harmless)
#
# VERIFIES WITH: bash verify_deployment.sh shows all checks passing

set -euxo pipefail

LOGFILE="/tmp/observability_bootstrap_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=========================================="
echo "OBSERVABILITY PLATFORM BOOTSTRAP"
echo "=========================================="
echo "Started: $(date)"
echo "Logging to: $LOGFILE"
echo ""

# ============================================================================
# STEP 1: Install system dependencies
# ============================================================================
echo ""
echo "=========================================="
echo "[1/6] Installing system dependencies"
echo "=========================================="

echo ""
echo "Installing PostgreSQL and server..."
sudo dnf install -y postgresql postgresql-server postgresql-contrib

echo ""
echo "Installing Python dependencies..."
sudo dnf install -y python3-psycopg2 python3-pip

echo ""
echo "Installing Node.js..."
sudo dnf install -y nodejs npm

echo ""
echo "Installing system monitoring tools..."
sudo dnf install -y strace perf sysstat iotop

echo ""
echo "Checking PostgreSQL version..."
psql --version

echo ""
echo "Checking if TimescaleDB is available in repos..."
if sudo dnf search timescaledb 2>&1 | grep -q timescaledb; then
    echo "TimescaleDB found in repos, installing..."
    # Try to find the right package name
    TIMESCALE_PKG=$(sudo dnf search timescaledb 2>&1 | grep "^timescaledb" | head -1 | awk '{print $1}')
    if [[ -n "$TIMESCALE_PKG" ]]; then
        sudo dnf install -y "$TIMESCALE_PKG"
    fi
else
    echo "WARNING: TimescaleDB not found in default repos"
    echo "You may need to add the TimescaleDB repository first:"
    echo "  https://packagecloud.io/timescale/timescaledb"
    echo ""
    echo "Continuing anyway - database will work without TimescaleDB"
    echo "(hypertable creation will be skipped)"
fi

# ============================================================================
# STEP 2: Initialize PostgreSQL
# ============================================================================
echo ""
echo "=========================================="
echo "[2/6] Initializing PostgreSQL"
echo "=========================================="

if [[ ! -d /var/lib/pgsql/data/base ]]; then
    echo "PostgreSQL not initialized - running initdb..."
    sudo postgresql-setup --initdb
else
    echo "PostgreSQL already initialized - skipping initdb"
fi

echo ""
echo "Enabling and starting PostgreSQL service..."
sudo systemctl enable postgresql
sudo systemctl start postgresql
sleep 2
sudo systemctl status postgresql --no-pager -l

# ============================================================================
# STEP 3: Create database and user
# ============================================================================
echo ""
echo "=========================================="
echo "[3/6] Creating database and user"
echo "=========================================="

echo ""
echo "Creating 'observability' database if not exists..."
sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='observability'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE observability;"

echo ""
echo "Creating 'observer' user if not exists..."
sudo -u postgres psql -c "SELECT 1 FROM pg_user WHERE usename='observer'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER observer WITH PASSWORD 'observer';"

echo ""
echo "Applying database schema..."
sudo -u postgres psql observability -f database/schema.sql

# ============================================================================
# STEP 4: Fix pg_hba.conf for password authentication
# ============================================================================
echo ""
echo "=========================================="
echo "[4/6] Configuring PostgreSQL authentication"
echo "=========================================="

echo ""
echo "Current local auth method:"
sudo grep "^local.*all.*all" /var/lib/pgsql/data/pg_hba.conf || echo "(no local all all line found)"

echo ""
echo "Backing up pg_hba.conf..."
sudo cp -v /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/pg_hba.conf.backup.$(date +%Y%m%d_%H%M%S)

echo ""
echo "Setting local connections to md5 (password) authentication..."
sudo sed -i '/^local.*all.*all.*peer/s/peer/md5/' /var/lib/pgsql/data/pg_hba.conf

echo ""
echo "After modification:"
sudo grep "^local.*all.*all" /var/lib/pgsql/data/pg_hba.conf

echo ""
echo "Restarting PostgreSQL to apply changes..."
sudo systemctl restart postgresql
sleep 3
sudo systemctl status postgresql --no-pager -l

echo ""
echo "Testing database connection with observer user..."
psql "dbname=observability user=observer password=observer host=localhost" -c "SELECT NOW() as current_time, version();"

# ============================================================================
# STEP 5: Install scripts and systemd units
# ============================================================================
echo ""
echo "=========================================="
echo "[5/6] Installing scripts and systemd units"
echo "=========================================="

echo ""
echo "Creating directories..."
sudo mkdir -pv /var/lib/observability/{evidence,repro_bundles,config_snapshots}
sudo mkdir -pv /var/log/observability
sudo mkdir -pv /etc/ssl/observability

echo ""
echo "Setting ownership..."
sudo chown -Rv owner:owner /var/lib/observability
sudo chown -Rv owner:owner /var/log/observability

echo ""
echo "Copying scripts to /usr/local/bin/..."
sudo cp -v scripts/*.sh /usr/local/bin/
sudo cp -v scripts/*.py /usr/local/bin/
sudo cp -v scripts/*.js /usr/local/bin/

echo ""
echo "Setting execute permissions..."
sudo chmod -v +x /usr/local/bin/*.{sh,py,js}

echo ""
echo "Installing systemd units..."
sudo cp -v systemd/*.service /etc/systemd/system/
sudo cp -v systemd/*.timer /etc/systemd/system/

echo ""
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo ""
echo "Enabling services..."
sudo systemctl enable journal-ingester.service
sudo systemctl enable psi-collector.timer
sudo systemctl enable firefox-gpu-monitor.timer
sudo systemctl enable auto-remediate.timer
sudo systemctl enable config-drift.timer
sudo systemctl enable dead-letter-replay.timer

# ============================================================================
# STEP 6: Start all services
# ============================================================================
echo ""
echo "=========================================="
echo "[6/6] Starting all services"
echo "=========================================="

echo ""
echo "Starting journal-ingester..."
sudo systemctl start journal-ingester.service
sudo systemctl status journal-ingester.service --no-pager -l

echo ""
echo "Starting timers..."
for timer in psi-collector firefox-gpu-monitor auto-remediate config-drift dead-letter-replay; do
    echo ""
    echo "Starting ${timer}.timer..."
    sudo systemctl start ${timer}.timer
    sudo systemctl status ${timer}.timer --no-pager -l
done

echo ""
echo "Starting websocket broker (if enabled)..."
if systemctl is-enabled websocket-broker.service; then
    sudo systemctl start websocket-broker.service
    sudo systemctl status websocket-broker.service --no-pager -l
else
    echo "websocket-broker.service not enabled - skipping"
fi

# ============================================================================
# VERIFICATION
# ============================================================================
echo ""
echo "=========================================="
echo "WAITING FOR SERVICES TO GENERATE LOGS"
echo "=========================================="
echo "Sleeping 30 seconds..."
sleep 30

echo ""
echo "=========================================="
echo "RUNNING DEPLOYMENT VERIFICATION"
echo "=========================================="
bash verify_deployment.sh

echo ""
echo "=========================================="
echo "✓✓✓ BOOTSTRAP COMPLETE ✓✓✓"
echo "=========================================="
echo "Finished: $(date)"
echo "Full log saved to: $LOGFILE"
echo ""
echo "Check dashboard:"
echo "  http://localhost:8080/"
echo ""
echo "View recent events:"
echo "  psql 'dbname=observability user=observer password=observer host=localhost' -c 'SELECT * FROM events ORDER BY time DESC LIMIT 20;'"
echo ""
echo "Collect logs for analysis:"
echo "  bash scripts/collect_logs.sh"
