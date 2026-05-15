-- PATH: database/schema.sql
-- 
-- WHAT: PostgreSQL + TimescaleDB schema for observability platform
-- WHY:  Centralizes all events from bash scripts, Python collectors, and systemd services
--       into a single time-series hypertable for querying and analysis
--
-- MENTAL MODEL BEFORE: no database structure defined
-- MENTAL MODEL AFTER:  events hypertable ready to receive time-stamped events
--
-- FAILURE MODE: if TimescaleDB extension not installed, CREATE EXTENSION fails;
--               if user 'observer' doesn't exist, GRANT fails
--
-- VERIFIES WITH: psql observability -c '\dt' shows events table
--                psql observability -c '\dx' shows timescaledb extension

-- Create database (run this as postgres user first if db doesn't exist):
-- CREATE DATABASE observability;

-- Connect to the database
\c observability

-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Create the events table
CREATE TABLE IF NOT EXISTS events (
    time        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    host        TEXT NOT NULL,
    pid         INTEGER,
    event_type  TEXT NOT NULL,
    severity    TEXT NOT NULL DEFAULT 'info',
    subsystem   TEXT NOT NULL,
    message     TEXT NOT NULL,
    raw_payload JSONB,
    
    -- Indices for common queries
    -- Note: TimescaleDB creates time index automatically via hypertable
    CONSTRAINT events_severity_check CHECK (severity IN ('debug', 'info', 'warning', 'error', 'critical'))
);

-- Convert to TimescaleDB hypertable
-- Partition by time with 1-day chunks for efficient querying
SELECT create_hypertable('events', 'time', 
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Create indices for common query patterns
CREATE INDEX IF NOT EXISTS idx_events_host ON events(host, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_subsystem ON events(subsystem, time DESC);
CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity, time DESC) WHERE severity IN ('error', 'critical');
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type, time DESC);

-- Create a view for recent errors
CREATE OR REPLACE VIEW recent_errors AS
SELECT time, host, subsystem, event_type, message
FROM events
WHERE severity IN ('error', 'critical')
ORDER BY time DESC
LIMIT 100;

-- Create user for the observability platform (if doesn't exist)
-- Password: observer (change in production!)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'observer') THEN
        CREATE USER observer WITH PASSWORD 'observer';
    END IF;
END
$$;

-- Grant permissions
GRANT CONNECT ON DATABASE observability TO observer;
GRANT SELECT, INSERT, UPDATE, DELETE ON events TO observer;
GRANT USAGE ON SCHEMA public TO observer;
GRANT SELECT ON recent_errors TO observer;

-- Verify setup
SELECT format('✓ Hypertable created: %s', hypertable_name)
FROM timescaledb_information.hypertables
WHERE hypertable_name = 'events';

SELECT format('✓ Indices created: %s', COUNT(*))
FROM pg_indexes
WHERE tablename = 'events';

SELECT format('✓ User observer has permissions: %s', COUNT(*))
FROM information_schema.table_privileges
WHERE grantee = 'observer' AND table_name = 'events';

-- Sample query patterns (commented out - for reference)
-- 
-- Recent events across all hosts:
-- SELECT time, host, subsystem, message FROM events ORDER BY time DESC LIMIT 20;
--
-- Errors only:
-- SELECT * FROM recent_errors;
--
-- Events by subsystem:
-- SELECT subsystem, COUNT(*), MAX(time) as last_seen
-- FROM events
-- GROUP BY subsystem
-- ORDER BY last_seen DESC;
--
-- Event rate per minute:
-- SELECT time_bucket('1 minute', time) AS minute, COUNT(*)
-- FROM events
-- WHERE time > NOW() - INTERVAL '1 hour'
-- GROUP BY minute
-- ORDER BY minute DESC;
