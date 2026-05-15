-- PATH: sql/migration_002_up.sql
-- Continuous aggregates and retention policies

-- Hourly continuous aggregate
CREATE MATERIALIZED VIEW IF NOT EXISTS events_hourly
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket,
       host,
       event_type,
       severity,
       COUNT(*) AS count,
       AVG((raw_payload->>'latency_ms')::float) AS avg_latency,
       MIN((raw_payload->>'latency_ms')::float) AS min_latency,
       MAX((raw_payload->>'latency_ms')::float) AS max_latency
FROM events
GROUP BY bucket, host, event_type, severity;

SELECT add_continuous_aggregate_policy('events_hourly',
    start_offset => INTERVAL '3 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists => TRUE);

-- Daily aggregate
CREATE MATERIALIZED VIEW IF NOT EXISTS events_daily
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', time) AS bucket,
       host,
       event_type,
       severity,
       COUNT(*) AS count
FROM events
GROUP BY bucket, host, event_type, severity;

SELECT add_continuous_aggregate_policy('events_daily',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day',
    if_not_exists => TRUE);

-- Retention policies
SELECT add_retention_policy('events', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_retention_policy('events_hourly', INTERVAL '90 days', if_not_exists => TRUE);
SELECT add_retention_policy('events_daily', INTERVAL '365 days', if_not_exists => TRUE);

-- Compression policy for events older than 7 days
ALTER TABLE events SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'host, event_type'
);

SELECT add_compression_policy('events', INTERVAL '7 days', if_not_exists => TRUE);

INSERT INTO schema_migrations (version) VALUES (2) ON CONFLICT DO NOTHING;
