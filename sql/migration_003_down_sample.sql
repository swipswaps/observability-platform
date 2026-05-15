-- PATH: sql/migration_003_down_sample.sql
-- Rollback migration 002 (example rollback script)

-- Remove compression policy
SELECT remove_compression_policy('events', if_exists => TRUE);

-- Remove retention policies
SELECT remove_retention_policy('events', if_exists => TRUE);
SELECT remove_retention_policy('events_hourly', if_exists => TRUE);
SELECT remove_retention_policy('events_daily', if_exists => TRUE);

-- Drop continuous aggregate policies
SELECT remove_continuous_aggregate_policy('events_daily', if_exists => TRUE);
SELECT remove_continuous_aggregate_policy('events_hourly', if_exists => TRUE);

-- Drop materialized views
DROP MATERIALIZED VIEW IF EXISTS events_daily CASCADE;
DROP MATERIALIZED VIEW IF EXISTS events_hourly CASCADE;

-- Remove migration record
DELETE FROM schema_migrations WHERE version = 2;
