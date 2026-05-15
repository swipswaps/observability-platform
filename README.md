# Observability Platform – Linux Latency & Failure Monitoring

Production-ready observability stack for Fedora Linux: captures systemd journal, PSI pressure, Firefox GPU diagnostics, network packet metadata, screenshots, config drift, and more. Visualized in real-time with Three.js.

## Quick Start

1. Install dependencies:
   ```bash
   sudo dnf install -y python3 python3-psycopg2 timescaledb postgresql nodejs npm \
       tcpdump bpftrace bcc-tools grim wf-recorder stress-ng chrony
   npm install ws jsonwebtoken
   pip3 install -r requirements.txt
   ```

2. Set up PostgreSQL / TimescaleDB:
   ```bash
   sudo systemctl enable --now postgresql
   sudo -u postgres psql -c "CREATE USER observer WITH PASSWORD 'strong_password';"
   sudo -u postgres psql -c "CREATE DATABASE observability OWNER observer;"
   psql -U observer -d observability -f sql/migration_001_up.sql
   psql -U observer -d observability -f sql/migration_002_up.sql
   ```

3. Deploy systemd units and scripts:
   ```bash
   sudo ./install.sh
   ```

4. Open dashboard:
   ```
   http://localhost:3000/dashboard/index.html
   ```

## Components

| Script | Purpose | Runs via |
|--------|---------|----------|
| journal_ingester.py | Streams systemd journal | systemd service |
| psi_collector.sh | Collects CPU/Memory/IO pressure | timer (5s) |
| firefox_gpu_monitor.sh | Firefox WebRender/GPU diagnostics | timer (5min) |
| screenshot_capture.sh | Takes screenshot on critical alerts | triggered by alert engine |
| config_drift.sh | Detects changes in .bashrc, packages, kernel cmdline | timer (daily) |
| failure_injection.sh | Simulates GPU stalls, OOM, packet loss | manual / CI |
| capture_repro_bundle.sh | Captures full environment for bug reproduction | triggered on critical event |
| federation_collector.sh | Forwards events to central DB with NTP drift correction | timer (5min) |
| adaptive_sampler.py | Drops non-critical events when queue >80% | integrated into ingestion |
| dead_letter_replay.py | Retries failed inserts from dead-letter file | timer (hourly) |
| validate_observability.sh | Self-test suite | timer (hourly) |
| websocket_broker_secure.js | TLS + JWT WebSocket server | systemd service |
| index.html | Three.js dashboard with timeline scrubber | static web server |

## Validation

After installation, run:
```bash
sudo systemctl start validate-observability.timer
# or manually:
sudo /usr/local/bin/validate_observability.sh
```

All services include `Restart=always` and `WatchdogSec=30`. Logs are sent to systemd journal:
```bash
journalctl -u journal-ingester -f
```

## Security

- WebSocket uses TLS (provide your own certificate in `/etc/ssl/observability/`)
- JWT authentication – set `JWT_SECRET` in `/etc/default/websocket-broker`
- Scripts run as non-root `observer` user where possible

## License

MIT
