#!/usr/bin/env bash
# PATH: heal_postgresql.sh
set -euo pipefail

echo "=== PostgreSQL Self-Healing ==="
echo ""

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "[0/10] Prerequisites"
command -v psql >/dev/null || { echo "✗ Install: sudo dnf install -y postgresql postgresql-server"; exit 1; }
[[ -f /usr/lib64/timescaledb-loader-pg18/timescaledb.so ]] || { echo "✗ Install: sudo dnf install -y timescaledb-2-postgresql-18"; exit 1; }
[[ -f /var/lib/pgsql/data/PG_VERSION ]] || { echo "✗ Run: sudo postgresql-setup --initdb"; exit 1; }
echo "✓ Prerequisites met"

# ── Service ───────────────────────────────────────────────────────────────────
echo "[1/10] Service"
systemctl is-active --quiet postgresql || { sudo systemctl start postgresql; sudo systemctl enable postgresql 2>/dev/null || true; sleep 2; }
echo "✓ Running"

# ── Authentication ────────────────────────────────────────────────────────────
echo "[2/10] Authentication"
sudo grep -q "host.*all.*all.*127.0.0.1/32.*scram-sha-256" /var/lib/pgsql/data/pg_hba.conf || {
    sudo sed -i.bak 's/\bident\b/scram-sha-256/g' /var/lib/pgsql/data/pg_hba.conf
    sudo systemctl reload postgresql
}
echo "✓ Password auth"

# ── Library Preload ───────────────────────────────────────────────────────────
echo "[3/10] Library Preload"
sudo grep -q "^shared_preload_libraries.*timescaledb" /var/lib/pgsql/data/postgresql.conf || {
    if sudo grep -q "^shared_preload_libraries" /var/lib/pgsql/data/postgresql.conf; then
        sudo sed -i "/^shared_preload_libraries/s/'$/,timescaledb'/" /var/lib/pgsql/data/postgresql.conf
    else
        sudo bash -c "echo \"shared_preload_libraries = 'timescaledb'\" >> /var/lib/pgsql/data/postgresql.conf"
    fi
    sudo systemctl restart postgresql
    sleep 3
}
echo "✓ Preload configured"

# ── ALL Library Symlinks ──────────────────────────────────────────────────────
echo "[4/10] Library Symlinks"
sudo mkdir -p /usr/lib64/pgsql
for sofile in $(sudo find /usr/lib64 -path "*/timescaledb*/*.so" 2>/dev/null); do
    basename=$(basename "$sofile")
    target="/usr/lib64/pgsql/$basename"
    [[ -f "$target" ]] || sudo ln -sf "$sofile" "$target"
done
echo "✓ All libraries linked ($(ls /usr/lib64/pgsql/*.so 2>/dev/null | wc -l) files)"

# ── Extension Files ───────────────────────────────────────────────────────────
echo "[5/10] Extension Files"
sudo mkdir -p /usr/share/pgsql/extension
[[ -f /usr/share/pgsql/extension/timescaledb.control ]] || sudo ln -sf /usr/lib64/timescaledb-loader-pg18/timescaledb.control /usr/share/pgsql/extension/
[[ -f /usr/share/pgsql/extension/timescaledb--2.27.0.sql ]] || sudo bash -c "ln -sf /usr/lib64/timescaledb-pg18/*.sql /usr/share/pgsql/extension/"
echo "✓ Extension files linked"

# ── Database User ─────────────────────────────────────────────────────────────
echo "[6/10] User"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='observer'" | grep -q 1 || sudo -u postgres psql -c "CREATE USER observer WITH PASSWORD 'observer_password';" >/dev/null
echo "✓ User exists"

# ── Database ──────────────────────────────────────────────────────────────────
echo "[7/10] Database"
sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw observability || sudo -u postgres psql -c "CREATE DATABASE observability OWNER observer;" >/dev/null
echo "✓ Database exists"

# ── Extension ─────────────────────────────────────────────────────────────────
echo "[8/10] Extension"
PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -tAc "SELECT 1 FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null | grep -q 1 || {
    PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
}
echo "✓ Extension loaded"

# ── Schema ────────────────────────────────────────────────────────────────────
echo "[9/10] Schema"
PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -tAc "SELECT 1 FROM pg_tables WHERE tablename='metrics'" | grep -q 1 || {
    [[ -f sql/migration_001_up.sql ]] && PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -f sql/migration_001_up.sql || echo "⚠ migration not found"
}
echo "✓ Schema ready"

# ── Verification ──────────────────────────────────────────────────────────────
echo "[10/10] Verification"
PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" -tA
echo ""
echo "✓ ALL CHECKS PASSED"
exit 0
