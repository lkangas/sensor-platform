-- 008_light_state.sql — light/plug state columns for the Hue collector's LOG_LIGHTS mode
-- (on/off as 0/1 — the Telegraf JSON parser drops booleans; brightness %, colour
-- temperature in mirek). Partial rows are normal: a Hue light event carries only the
-- sub-objects that changed.
--
-- Apply to the live DB, THEN redo the 004 view dance exactly as documented in
-- 007_hue_columns.sql (drop sensor_readings_1min_cal → re-apply 004 → recreate the
-- 1min _cal view from 005), or the new columns won't surface in sensor_readings_cal.
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS on_state   SMALLINT;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS brightness DOUBLE PRECISION;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS mirek      SMALLINT;
