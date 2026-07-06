-- 007_hue_columns.sql — DRAFT (pairs with edge/hue-collector; do not apply before that
-- lands). Event/state columns for non-Ruuvi sources, first user: Philips Hue.
--   motion       0/1 motion events (SMALLINT not BOOLEAN: the Telegraf JSON parser drops
--                booleans, so the collector publishes numeric 0/1)
--   event        discrete events as text, e.g. Hue remote 'b2:short_release'
--   battery_pct  battery percentage (Hue reports %; Ruuvi battery_mv stays separate — mV)
--
-- Apply to the live DB, THEN re-apply 004_calibration.sql: sensor_readings_cal is
-- `SELECT sr.*` and freezes its column list at CREATE time (see 004's header).
-- The hourly/1-min aggregates deliberately ignore these columns (events aren't averages).
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS motion      SMALLINT;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS event       TEXT;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS battery_pct SMALLINT;
