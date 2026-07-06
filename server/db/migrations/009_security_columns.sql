-- 009_security_columns.sql — counters for the ssh-monitor feeder (source='security'):
-- per-interval SSH attempt/access counts from journald + fail2ban ban gauges. Plain
-- integers; the aggregates ignore them (counts, not averages).
--
-- Apply to the live DB, THEN redo the 004 view dance exactly as documented in
-- 007_hue_columns.sql (drop sensor_readings_1min_cal → re-apply 004 → recreate the
-- 1min _cal view from 005), or the new columns won't surface in sensor_readings_cal.
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS ssh_failed       INTEGER;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS ssh_accepted     INTEGER;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS ssh_ips          INTEGER;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS f2b_banned       INTEGER;
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS f2b_banned_total INTEGER;
