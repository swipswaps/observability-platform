#!/usr/bin/env bash
# PATH: fix_timescaledb.sh
set -euo pipefail

echo "=== TimescaleDB Library Fix ==="

# Find where timescaledb .so files are
echo "Searching for timescaledb libraries..."
TIMESCALE_SO=$(sudo find /usr -name "*timescaledb*.so" 2>/dev/null | head -1)

if [[ -z "$TIMESCALE_SO" ]]; then
    echo "ERROR: No timescaledb .so file found"
    echo "Reinstalling timescaledb-2-postgresql-18..."
    sudo dnf reinstall -y timescaledb-2-postgresql-18
    TIMESCALE_SO=$(sudo find /usr -name "*timescaledb*.so" 2>/dev/null | head -1)
fi

echo "Found: $TIMESCALE_SO"

# Find where PostgreSQL expects libraries
PG_LIBDIR=$(sudo -u postgres psql -t -c "SHOW dynamic_library_path;" 2>/dev/null | tr ':' '\n' | grep -v '^\$' | head -1 | xargs)

if [[ -z "$PG_LIBDIR" ]]; then
    PG_LIBDIR="/usr/lib64/pgsql"
fi

echo "PostgreSQL library directory: $PG_LIBDIR"

# Create symlink if needed
BASENAME=$(basename "$TIMESCALE_SO")
TARGET="$PG_LIBDIR/timescaledb.so"

if [[ ! -f "$TARGET" ]]; then
    echo "Creating symlink: $TARGET -> $TIMESCALE_SO"
    sudo mkdir -p "$PG_LIBDIR"
    sudo ln -sf "$TIMESCALE_SO" "$TARGET"
else
    echo "Library already exists at $TARGET"
fi

# Verify symlink works
if [[ -f "$TARGET" ]]; then
    echo "✓ Library accessible at $TARGET"
else
    echo "✗ Library still not accessible"
    exit 1
fi

# Restart PostgreSQL
echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql

# Check status
if sudo systemctl is-active --quiet postgresql; then
    echo "✓ PostgreSQL running"
else
    echo "✗ PostgreSQL failed to start"
    sudo journalctl -u postgresql -n 20 --no-pager
    exit 1
fi

echo "=== Fix Complete ==="
