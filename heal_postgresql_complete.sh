#!/usr/bin/env bash
# PATH: heal_postgresql_complete.sh
set -euxo pipefail  # Added -x to show every command executed

LOGFILE="heal_postgresql.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== PostgreSQL + TimescaleDB + SELinux Setup ($(date)) ==="
echo "Logging to: $LOGFILE"
echo ""

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "[0/12] Prerequisites"
command -v psql
stat /usr/lib64/timescaledb-loader-pg18/timescaledb.so
stat /var/lib/pgsql/data/PG_VERSION
echo "✓ Prerequisites met"

# ── Service ───────────────────────────────────────────────────────────────────
echo "[1/12] Service"
systemctl is-active postgresql || {
    echo "  Starting PostgreSQL..."
    sudo systemctl start postgresql
    sudo systemctl status postgresql --no-pager -l
    sudo systemctl enable postgresql
    sleep 2
}
sudo systemctl status postgresql --no-pager -l | head -20
echo "✓ Running"

# ── Authentication ────────────────────────────────────────────────────────────
echo "[2/12] Authentication"
echo "  Current pg_hba.conf auth methods:"
sudo grep -E "^host" /var/lib/pgsql/data/pg_hba.conf
if ! sudo grep -q "host.*all.*all.*127.0.0.1/32.*scram-sha-256" /var/lib/pgsql/data/pg_hba.conf; then
    echo "  Updating pg_hba.conf..."
    sudo sed -i.bak 's/\bident\b/scram-sha-256/g' /var/lib/pgsql/data/pg_hba.conf
    echo "  After update:"
    sudo grep -E "^host" /var/lib/pgsql/data/pg_hba.conf
    echo "  Reloading PostgreSQL..."
    sudo systemctl reload postgresql
fi
echo "✓ Password auth"

# ── Library Preload ───────────────────────────────────────────────────────────
echo "[3/12] Library Preload"
echo "  Current shared_preload_libraries:"
sudo grep "^shared_preload_libraries" /var/lib/pgsql/data/postgresql.conf || echo "  (not set)"
if ! sudo grep -q "^shared_preload_libraries.*timescaledb" /var/lib/pgsql/data/postgresql.conf; then
    echo "  Configuring shared_preload_libraries..."
    if sudo grep -q "^shared_preload_libraries" /var/lib/pgsql/data/postgresql.conf; then
        sudo sed -i "/^shared_preload_libraries/s/'$/,timescaledb'/" /var/lib/pgsql/data/postgresql.conf
    else
        sudo bash -c "echo \"shared_preload_libraries = 'timescaledb'\" >> /var/lib/pgsql/data/postgresql.conf"
    fi
    echo "  After update:"
    sudo grep "^shared_preload_libraries" /var/lib/pgsql/data/postgresql.conf
    echo "  Restarting PostgreSQL..."
    time sudo systemctl restart postgresql
    sleep 3
fi
echo "✓ Preload configured"

# ── Library Symlinks ──────────────────────────────────────────────────────────
echo "[4/12] Library Symlinks"
echo "  Finding TimescaleDB libraries..."
sudo find /usr/lib64 -path "*/timescaledb*/*.so" -ls
sudo mkdir -p /usr/lib64/pgsql
for sofile in $(sudo find /usr/lib64 -path "*/timescaledb*/*.so"); do
    basename=$(basename "$sofile")
    target="/usr/lib64/pgsql/$basename"
    if [[ ! -f "$target" ]]; then
        echo "  Linking $basename -> $sofile"
        sudo ln -sf "$sofile" "$target"
        ls -la "$target"
    fi
done
echo "  Final state:"
ls -la /usr/lib64/pgsql/timescaledb*.so
echo "✓ Linked $(ls /usr/lib64/pgsql/timescaledb*.so | wc -l) TimescaleDB libs"

# ── Extension Files ───────────────────────────────────────────────────────────
echo "[5/12] Extension Files"
sudo mkdir -p /usr/share/pgsql/extension
if [[ ! -f /usr/share/pgsql/extension/timescaledb.control ]]; then
    echo "  Linking control file..."
    sudo ln -sf /usr/lib64/timescaledb-loader-pg18/timescaledb.control /usr/share/pgsql/extension/
    ls -la /usr/share/pgsql/extension/timescaledb.control
fi
if [[ ! -f /usr/share/pgsql/extension/timescaledb--2.27.0.sql ]]; then
    echo "  Linking SQL files..."
    sudo bash -c "ln -sf /usr/lib64/timescaledb-pg18/*.sql /usr/share/pgsql/extension/"
    ls -la /usr/share/pgsql/extension/timescaledb*.sql | head -5
fi
echo "✓ Extension files linked"

# ── SELinux Contexts ──────────────────────────────────────────────────────────
echo "[6/12] SELinux Contexts"
if command -v getenforce >/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    echo "  SELinux status: $(getenforce)"
    echo "  Current library contexts:"
    ls -laZ /usr/lib64/pgsql/timescaledb*.so
    echo "  Setting library contexts..."
    for sofile in /usr/lib64/pgsql/timescaledb*.so; do
        if [[ -L "$sofile" ]]; then
            sudo chcon -h system_u:object_r:lib_t:s0 "$sofile"
            ls -laZ "$sofile"
        fi
    done
    echo "  Setting extension file contexts..."
    sudo chcon -R -t usr_t /usr/share/pgsql/extension/timescaledb*
    ls -laZ /usr/share/pgsql/extension/timescaledb* | head -3
    echo "✓ SELinux contexts set"
else
    echo "✓ SELinux disabled"
fi

# ── SELinux Booleans (SHOWS FULL OUTPUT) ─────────────────────────────────────
echo "[7/12] SELinux Booleans"
if command -v getsebool >/dev/null 2>&1; then
    echo "  Before:"
    getsebool postgresql_can_rsync nis_enabled
    echo "  Setting postgresql_can_rsync (with timing)..."
    time sudo setsebool -P postgresql_can_rsync on
    echo "  Setting nis_enabled (with timing)..."
    time sudo setsebool -P nis_enabled on
    echo "  After:"
    getsebool postgresql_can_rsync nis_enabled
    echo "✓ SELinux booleans configured"
else
    echo "✓ SELinux booleans (not available)"
fi

# ── Database User ─────────────────────────────────────────────────────────────
echo "[8/12] Database User"
echo "  Checking for 'observer' user..."
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='observer'" || true
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='observer'" | grep -q 1; then
    echo "  Creating user 'observer'..."
    sudo -u postgres psql -c "CREATE USER observer WITH PASSWORD 'observer_password';"
fi
echo "✓ User exists"

# ── Database ──────────────────────────────────────────────────────────────────
echo "[9/12] Database"
echo "  Current databases:"
sudo -u postgres psql -lqt | grep -E "^\s*(postgres|template|observability)"
if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw observability; then
    echo "  Creating database 'observability'..."
    sudo -u postgres psql -c "CREATE DATABASE observability OWNER observer;"
fi
echo "✓ Database exists"

# ── Extension ─────────────────────────────────────────────────────────────────
echo "[10/12] Extension"
echo "  Checking extensions..."
PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "SELECT extname, extversion FROM pg_extension;" || true
if ! PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -tAc "SELECT 1 FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null | grep -q 1; then
    echo "  Creating TimescaleDB extension..."
    PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
fi
echo "✓ Extension loaded"

# ── Schema ────────────────────────────────────────────────────────────────────
echo "[11/12] Schema"
echo "  Current tables:"
PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "\dt" || echo "  (no tables)"
if ! PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -tAc "SELECT 1 FROM pg_tables WHERE tablename='metrics'" | grep -q 1; then
    if [[ -f sql/migration_001_up.sql ]]; then
        echo "  Running migration_001_up.sql..."
        PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -f sql/migration_001_up.sql
    else
        echo "⚠ sql/migration_001_up.sql not found"
    fi
fi
echo "✓ Schema ready"

# ── Verification ──────────────────────────────────────────────────────────────
echo "[12/12] Verification"
VERSION=$(PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -tAc "SELECT extversion FROM pg_extension WHERE extname='timescaledb';")
echo "✓ TimescaleDB $VERSION loaded"

echo ""
echo "✓ ALL CHECKS PASSED"
echo "Full log: $LOGFILE"
exit 0
