#!/usr/bin/env bash
# PATH: scripts/capture_repro_bundle.sh
set -euxo pipefail

LOGFILE="/var/log/observability/repro_bundle.log"
exec > >(tee -a "$LOGFILE") 2>&1

BUNDLE_DIR="/var/lib/observability/repro_bundles"
mkdir -p "$BUNDLE_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE_NAME="repro_${TIMESTAMP}"
WORK_DIR="/tmp/${BUNDLE_NAME}"

echo "=== Creating Reproduction Bundle: $BUNDLE_NAME ==="
mkdir -pv "$WORK_DIR"/{logs,configs,process_state,network}

echo "[1/8] Capturing system logs..."
journalctl -n 1000 > "$WORK_DIR/logs/journal.txt"
dmesg > "$WORK_DIR/logs/dmesg.txt"

echo "[2/8] Capturing configurations..."
cp -v /etc/fstab "$WORK_DIR/configs/" || true
cp -v /etc/sysctl.conf "$WORK_DIR/configs/" || true
sysctl -a > "$WORK_DIR/configs/sysctl_all.txt"

echo "[3/8] Capturing process state..."
ps auxf > "$WORK_DIR/process_state/ps_tree.txt"
top -b -n 1 > "$WORK_DIR/process_state/top_snapshot.txt"

echo "[4/8] Capturing network state..."
ss -tulpn > "$WORK_DIR/network/sockets.txt"
ip addr > "$WORK_DIR/network/ip_addr.txt"
ip route > "$WORK_DIR/network/ip_route.txt"

echo "[5/8] Capturing memory info..."
free -h > "$WORK_DIR/process_state/free.txt"
cat /proc/meminfo > "$WORK_DIR/process_state/meminfo.txt"

echo "[6/8] Capturing disk info..."
df -h > "$WORK_DIR/process_state/df.txt"
lsblk > "$WORK_DIR/process_state/lsblk.txt"

echo "[7/8] Creating tarball..."
BUNDLE_FILE="$BUNDLE_DIR/${BUNDLE_NAME}.tar.gz"
tar -czf "$BUNDLE_FILE" -C /tmp "$BUNDLE_NAME"
ls -lh "$BUNDLE_FILE"

echo "[8/8] Cleanup..."
rm -rf "$WORK_DIR"

echo "Bundle created: $BUNDLE_FILE"
