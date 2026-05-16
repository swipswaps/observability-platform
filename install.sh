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
echo "=== Creating Database and User ==="

sudo -u postgres psql << 'PGSQL'
-- Create database if not exists
SELECT 'CREATE DATABASE observability'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'observability')\gexec

-- Set md5 password encryption for this session
SET password_encryption = 'md5';

-- Create or update observer user with md5-hashed password
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_user WHERE usename = 'observer') THEN
        ALTER USER observer WITH PASSWORD 'observer';
    ELSE
        CREATE USER observer WITH PASSWORD 'observer';
    END IF;
END
$$;
PGSQL

echo ""
echo "Applying database schema..."
sudo -u postgres psql observability -f database/schema.sql

echo ""
echo "=== Fixing PostgreSQL Authentication ==="

sudo python3 << 'PYSCRIPT'
import sys

hba_file = "/var/lib/pgsql/data/pg_hba.conf"

with open(hba_file, 'r') as f:
    lines = f.readlines()

# Remove all existing observability/observer lines
print("Cleaning old observability/observer rules...", file=sys.stderr, flush=True)
cleaned_lines = [line for line in lines 
                 if not ('observability' in line and 'observer' in line 
                         and not line.strip().startswith('#'))]

# Add new rules after header
new_lines = []
inserted = False

for line in cleaned_lines:
    new_lines.append(line)
    if not inserted and line.strip().startswith('# TYPE') and 'DATABASE' in line:
        new_lines.append('local   observability   observer                                md5\n')
        new_lines.append('host    observability   observer    127.0.0.1/32            md5\n')
        new_lines.append('host    observability   observer    ::1/128                 md5\n')
        print("Added md5 auth rules for observer", file=sys.stderr, flush=True)
        inserted = True

with open(hba_file, 'w') as f:
    f.writelines(new_lines)
PYSCRIPT

echo ""
echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql
sleep 2

echo ""
echo "Testing connection..."
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
echo "Start services:"
echo "  sudo systemctl start journal-ingester psi-collector.timer firefox-gpu-monitor.timer auto-remediate.timer"
