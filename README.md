# Observability Platform – Linux Latency & Failure Monitoring

Production-ready observability stack for Fedora Linux: captures systemd journal, PSI pressure, Firefox GPU diagnostics, network packet metadata, screenshots, config drift, and more. Visualized in real-time with Three.js.

## Quick Start

1. Install dependencies:
   ```bash
   sudo dnf install -y python3 python3-psycopg2 timescaledb postgresql nodejs npm \
       tcpdump bpftrace bcc-tools grim wf-recorder stress-ng chrony
   npm install ws jsonwebtoken
   pip3 install -r requirements.txt

    Set up PostgreSQL / TimescaleDB:
    bash

    sudo systemctl enable --now postgresql
    sudo -u postgres psql -c "CREATE USER observer WITH PASSWORD 'strong_password';"
    sudo -u postgres psql -c "CREATE DATABASE observability OWNER observer;"
    psql -U observer -d observability -f sql/migration_001_up.sql
    psql -U observer -d observability -f sql/migration_002_up.sql

    Deploy systemd units and scripts:
    bash

    sudo ./install.sh

    Open dashboard:
    text

    http://localhost:3000/dashboard/index.html

Components
Script	Purpose	Runs via
journal_ingester.py	Streams systemd journal	systemd service
psi_collector.sh	Collects CPU/Memory/IO pressure	timer (5s)
firefox_gpu_monitor.sh	Firefox WebRender/GPU diagnostics	timer (5min)
screenshot_capture.sh	Takes screenshot on critical alerts	triggered by alert engine
config_drift.sh	Detects changes in .bashrc, packages, kernel cmdline	timer (daily)
failure_injection.sh	Simulates GPU stalls, OOM, packet loss	manual / CI
capture_repro_bundle.sh	Captures full environment for bug reproduction	triggered on critical event
federation_collector.sh	Forwards events to central DB with NTP drift correction	timer (5min)
adaptive_sampler.py	Drops non-critical events when queue >80%	integrated into ingestion
dead_letter_replay.py	Retries failed inserts from dead-letter file	timer (hourly)
validate_observability.sh	Self-test suite	timer (hourly)
websocket_broker_secure.js	TLS + JWT WebSocket server	systemd service
index.html	Three.js dashboard with timeline scrubber	static web server
Validation

After installation, run:
bash

sudo systemctl start validate-observability.timer
# or manually:
sudo /usr/local/bin/validate_observability.sh

All services include Restart=always and WatchdogSec=30. Logs are sent to systemd journal:
bash

journalctl -u journal-ingester -f

Security

    WebSocket uses TLS (provide your own certificate in /etc/ssl/observability/)

    JWT authentication – set JWT_SECRET in /etc/default/websocket-broker

    Scripts run as non-root observer user where possible

License

MIT
Firefox Contention Diagnostic & Self‑Healing

firefox_contention_diagnostic_0099.sh is a comprehensive tool to diagnose and fix Firefox performance problems on Linux (high CPU, I/O pressure, WebGL fallback, memory fragmentation). It collects per‑thread CPU, PSI pressure, stack traces, and automatically applies fixes.
Features

    Detects high‑CPU threads (Renderer, compositor, etc.)

    Measures PSI (Pressure Stall Information) for CPU, memory, I/O

    Collects stack traces via GDB (with 20s timeout, fallback to /proc/*/stack and perf)

    Forces hardware acceleration (WebRender, WebGL, layers acceleration)

    Clears all Firefox caches (profile, system cache, storage)

    Vacuums SQLite databases (places.sqlite, favicons.sqlite, cookies.sqlite)

    Disables Firefox Sync (eliminates login error noise)

    Applies runtime fixes: renicing, CPU pinning (taskset), memory compaction, page cache drop

    Stores results in PostgreSQL for trend analysis

Usage
bash

sudo ./firefox_contention_diagnostic_0099.sh [duration] [--auto-fix] [--pin-core N] [--no-gdb]

    duration – sampling time in seconds (default 10)

    --auto-fix – apply all self‑healing steps

    --pin-core N – pin Renderer thread to CPU core N

    --no-gdb – disable GDB (use only /proc/*/stack and perf)

Quick start
bash

chmod +x firefox_contention_diagnostic_0099.sh
sudo ./firefox_contention_diagnostic_0099.sh --auto-fix

After the first run, wait 30 seconds and run again to verify improvements.
Dependencies

    python3 + websockets (optional – fallback works)

    timeout (coreutils)

    bc or awk

    gdb (optional)

    perf (optional)

    sqlite3 (optional)

    taskset (for CPU pinning)

SELinux and ptrace_scope are temporarily adjusted during the script (restored on exit).
Output

The script prints a diagnostic summary, inserts data into the events table (JSONB), and provides a final status report. Example:
text

=== FINAL STATUS REPORT ===
WebGL/GPU acceleration forced: YES
All caches cleared: YES
SQLite databases vacuumed: YES
CDP WebSocket: WORKING
Renderer thread CPU: 3.1% (target <10%)
Overall Firefox CPU: 41.1% (target <25%)
PSI I/O pressure: 90.22% (target <20%)

Troubleshooting

    GDB times out / stack traces unreadable – Firefox internal ptrace restrictions. Use --no-gdb; fallback works. Run perf top -p $(pgrep firefox) for live analysis.

    High I/O pressure – swap thrashing or heavy disk usage. Close other apps, reduce vm.swappiness, add RAM, or reboot.

    CDP WebSocket not found – Script now creates a blank page first; fallback to command line works.

See the script header for full documentation.
