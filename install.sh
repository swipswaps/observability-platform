#!/usr/bin/env bash
# PATH: install.sh
set -euxo pipefail

echo "=== Observability Platform Installation ==="

# Create directories
sudo mkdir -pv /var/lib/observability/{evidence,repro_bundles,config_snapshots}
sudo mkdir -pv /var/log/observability
sudo mkdir -pv /etc/ssl/observability

# Set ownership
sudo chown -R owner:owner /var/lib/observability
sudo chown -R owner:owner /var/log/observability

echo ""
echo "=== Fixing PostgreSQL Authentication ==="
echo "Current pg_hba.conf local auth:"
sudo grep "^local.*all.*all" /var/lib/pgsql/data/pg_hba.conf || echo "(no local all all line found)"

echo ""
echo "Backing up pg_hba.conf..."
sudo cp -v /var/lib/pgsql/data/pg_hba.conf /var/lib/pgsql/data/pg_hba.conf.backup

echo ""
echo "Setting local connections to md5 auth for observer user..."
sudo sed -i '/^local.*all.*all.*peer/s/peer/md5/' /var/lib/pgsql/data/pg_hba.conf

echo ""
echo "After fix:"
sudo grep "^local.*all.*all" /var/lib/pgsql/data/pg_hba.conf

echo ""
echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql
sleep 2
sudo systemctl status postgresql --no-pager -l

echo ""
echo "Testing database connection..."
psql "dbname=observability user=observer password=observer host=localhost" -c "SELECT 1;"

echo ""
echo "=== Copying Scripts ==="
sudo cp -v scripts/*.sh /usr/local/bin/
sudo cp -v scripts/*.py /usr/local/bin/
sudo cp -v scripts/*.js /usr/local/bin/
sudo chmod +x /usr/local/bin/*.{sh,py,js}

echo ""
echo "=== Installing Systemd Units ==="
sudo cp -v systemd/*.service /etc/systemd/system/
sudo cp -v systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload

echo ""
echo "=== Enabling Services ==="
sudo systemctl enable journal-ingester.service
sudo systemctl enable psi-collector.timer
sudo systemctl enable firefox-gpu-monitor.timer
sudo systemctl enable auto-remediate.timer

echo ""
echo "✓✓✓ Installation complete ✓✓✓"
echo ""
echo "Start services now:"
echo "  sudo systemctl start journal-ingester"
echo "  sudo systemctl start psi-collector.timer"
echo "  sudo systemctl start firefox-gpu-monitor.timer"
echo "  sudo systemctl start auto-remediate.timer"
echo ""
echo "Verify:"
echo "  sudo systemctl status journal-ingester"
echo "  sudo journalctl -u journal-ingester -f"
echo "  ls -lh /var/log/observability/"
