#!/usr/bin/env bash
# PATH: diagnose_and_fix.sh
set -euo pipefail

echo "=== TimescaleDB Diagnostic ==="
echo ""

# Find all TimescaleDB .so files
echo "[1] Finding all TimescaleDB libraries..."
sudo find /usr/lib64 -name "*timescaledb*.so" 2>/dev/null | sort

echo ""
echo "[2] Current /usr/lib64/pgsql/ contents..."
ls -la /usr/lib64/pgsql/ 2>/dev/null || echo "  (directory empty)"

echo ""
echo "[3] PostgreSQL dynamic_library_path..."
sudo -u postgres psql -tAc "SHOW dynamic_library_path;" 2>/dev/null || echo "  (service not running)"

echo ""
echo "[4] Linking ALL TimescaleDB libraries..."
sudo mkdir -p /usr/lib64/pgsql
for sofile in $(sudo find /usr/lib64 -name "*timescaledb*.so" 2>/dev/null); do
    basename=$(basename "$sofile")
    target="/usr/lib64/pgsql/$basename"
    if [[ ! -f "$target" ]]; then
        echo "  → Linking $basename"
        sudo ln -sf "$sofile" "$target"
    else
        echo "  ✓ Already linked: $basename"
    fi
done

echo ""
echo "[5] Verifying links..."
ls -la /usr/lib64/pgsql/*.so

echo ""
echo "[6] Testing CREATE EXTENSION..."
if PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "DROP EXTENSION IF EXISTS timescaledb CASCADE;" >/dev/null 2>&1; then
    echo "  Dropped existing extension"
fi

if PGPASSWORD='observer_password' psql -U observer -h 127.0.0.1 -d observability -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" 2>&1; then
    echo "  ✓ Extension created successfully"
else
    echo "  ✗ Extension creation failed"
    exit 1
fi

echo ""
echo "✓ DIAGNOSTIC COMPLETE"
