-- 007_hue_columns.sql — event/state columns for non-Ruuvi sources, first user: Philips
-- Hue (pairs with edge/hue-collector; applied — Hue is live on the home node).
--   motion       0/1 motion events (SMALLINT not BOOLEAN: the Telegraf JSON parser drops
--                booleans, so the collector publishes numeric 0/1)
--   event        discrete events as text, e.g. Hue remote 'b2:short_release'
--   battery_pct  battery percentage (Hue reports %; Ruuvi battery_mv stays separate — mV)
--
-- Apply to the live DB, THEN re-apply 004_calibration.sql: sensor_readings_cal is
-- `SELECT sr.*` and freezes its column list at CREATE time (see 004's header).
-- ⚠ 004 drops sensor_offset_current, which 005's sensor_readings_1min_cal depends on —
-- re-applying 004 fails unless that view is dropped first and recreated after:
--   1. this file
--   2. DROP VIEW IF EXISTS sensor_readings_1min_cal;
--   3. 004_calibration.sql
--   4. the CREATE OR REPLACE VIEW sensor_readings_1min_cal block from 005
-- The hourly/1-min aggregates deliberately ignore these columns (events aren't averages).
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS motion      SMALLINT;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS event       TEXT;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS battery_pct SMALLINT;
