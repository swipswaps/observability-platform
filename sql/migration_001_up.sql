-- PATH: sql/migration_001_up.sql
-- Initial schema creation for observability platform

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS events (
    time            TIMESTAMPTZ NOT NULL,
    host            TEXT NOT NULL,
    pid             INTEGER,
    tid             INTEGER,
    event_type      TEXT NOT NULL,
    severity        TEXT,
    correlation_id  UUID,
    subsystem       TEXT,
    message         TEXT,
    stacktrace      TEXT,
    raw_payload     JSONB,
    schema_version  INTEGER DEFAULT 1
);

SELECT create_hypertable('events', 'time', chunk_time_interval => INTERVAL '1 day', if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_events_host_time ON events (host, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_type_time ON events (event_type, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_severity_time ON events (severity, time DESC) WHERE severity IN ('error', 'critical');
CREATE INDEX IF NOT EXISTS idx_events_correlation ON events (correlation_id) WHERE correlation_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO schema_migrations (version) VALUES (1) ON CONFLICT DO NOTHING;
