-- 005_onemin_aggregate.sql — a 1-MINUTE continuous aggregate so long dashboard windows
-- (>1 h) read pre-summarised buckets instead of scanning raw. Short windows (<=1 h) keep
-- reading raw for full resolution; the panels switch source by time range. Design: plan §11
-- ("Data lifecycle"). Companion to the 1-hour rollup in init/001_schema.sql and the
-- query-time calibration in 004_calibration.sql.
--
-- Apply to a live DB (psql AUTOCOMMIT — do NOT wrap in BEGIN/COMMIT: creating a continuous
-- aggregate and CALL refresh_continuous_aggregate both refuse to run inside a txn block):
--   docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1 < 005_onemin_aggregate.sql
--
-- RE-APPLY after any later `ALTER TABLE sensor_readings ADD COLUMN` you want summarised:
-- add the column here and to sensor_readings_1min_cal, then re-run.

-- Raw 1-minute rollup. Offsets are NOT applied here (like the hourly rollup) — they are a
-- constant per sensor, so avg(raw)-offset == avg(raw-offset); the *_cal view below subtracts
-- them at query time, identical to 004's treatment of the hourly view. Aggregators chosen per
-- column: avg for the plotted line; min/max where the envelope matters (temp) or spikes do
-- (co2); min for battery (slow decay); max for the monotone counters (seq, movement).
CREATE MATERIALIZED VIEW IF NOT EXISTS sensor_readings_1min
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 minute', time) AS bucket,
  site, sensor_id,
  avg(temperature) AS temp_avg,
  min(temperature) AS temp_min,
  max(temperature) AS temp_max,
  avg(humidity)    AS hum_avg,
  avg(pressure)    AS pressure_avg,
  avg(co2)         AS co2_avg,
  max(co2)         AS co2_max,
  avg(pm1_0)       AS pm1_0_avg,
  avg(pm2_5)       AS pm2_5_avg,
  avg(pm4_0)       AS pm4_0_avg,
  avg(pm10_0)      AS pm10_0_avg,
  avg(voc)         AS voc_avg,
  avg(nox)         AS nox_avg,
  min(battery_mv)  AS battery_min,
  avg(rssi)        AS rssi_avg,
  max(seq)         AS seq_max,
  max(movement_ctr) AS movement_max,
  avg(accel_z)     AS accel_z_avg
FROM sensor_readings
GROUP BY bucket, site, sensor_id
WITH NO DATA;

-- Keep it current: materialise up to 1 min ago every 2 min, re-scanning the last 6 h so
-- modestly-late data (e.g. summer site reconnecting) is picked up. Real-time aggregation is
-- ON by default, so queries also stitch in the not-yet-materialised tail computed live from
-- raw — the newest minute always shows. (Data arriving >6 h late needs a manual
-- refresh_continuous_aggregate; rare.)
SELECT add_continuous_aggregate_policy('sensor_readings_1min',
  start_offset      => INTERVAL '6 hours',
  end_offset        => INTERVAL '1 minute',
  schedule_interval => INTERVAL '2 minutes',
  if_not_exists     => true);

-- One-time backfill of all existing history (the policy above only covers the last 6 h).
CALL refresh_continuous_aggregate('sensor_readings_1min', NULL, NULL);

-- Calibrated view: raw aggregate columns preserved, *_cal added alongside (mirror of
-- sensor_readings_hourly_cal in 004). NULL offset -> unchanged (COALESCE 0).
CREATE OR REPLACE VIEW sensor_readings_1min_cal AS
SELECT a.*,
       a.temp_avg     - COALESCE(t.offset_value, 0)  AS temp_avg_cal,
       a.temp_min     - COALESCE(t.offset_value, 0)  AS temp_min_cal,
       a.temp_max     - COALESCE(t.offset_value, 0)  AS temp_max_cal,
       a.hum_avg      - COALESCE(h.offset_value, 0)  AS hum_avg_cal,
       a.pressure_avg - COALESCE(p.offset_value, 0)  AS pressure_avg_cal
FROM sensor_readings_1min a
LEFT JOIN sensor_offset_current t ON t.sensor_id = a.sensor_id AND t.metric = 'temperature'
LEFT JOIN sensor_offset_current h ON h.sensor_id = a.sensor_id AND h.metric = 'humidity'
LEFT JOIN sensor_offset_current p ON p.sensor_id = a.sensor_id AND p.metric = 'pressure';
