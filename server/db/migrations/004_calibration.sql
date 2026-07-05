-- 004_calibration.sql — cross-calibration: per-sensor correction offsets applied at QUERY
-- time (raw data preserved; a re-calibration corrects all history instantly). Design &
-- rationale: docs/local/CALIBRATION-PLAN.md (§3). Offsets are computed and inserted by
-- scripts/calibrate-offsets.sh (which requires this migration).
--
-- Apply to a live DB (init/001_schema.sql covers fresh deploys). Idempotent:
--   docker exec -i server-timescaledb-1 psql -U postgres -d sensors < 004_calibration.sql
--
-- RE-APPLY after any later `ALTER TABLE sensor_readings ADD COLUMN` (a future 00N_*.sql):
-- sensor_readings_cal below is `SELECT sr.*`, and a view freezes that column list at CREATE
-- time — a newly added column won't surface in the calibrated view until this is re-run.

BEGIN;

-- Offset history: one row per sensor/metric per calibration run; the newest wins (view
-- below). Keyed on sensor_id (BLE MAC) ALONE -> site-agnostic: an offset is intrinsic to
-- the physical tag and travels with it (Koti -> Vaunu), exactly like sensor_meta.
CREATE TABLE IF NOT EXISTS sensor_calibration (
  sensor_id     TEXT NOT NULL,                 -- BLE MAC, colon form upper-case; joins sensor_readings/sensor_meta
  metric        TEXT NOT NULL                  -- which reading the offset corrects
                  CHECK (metric IN ('temperature','humidity','pressure')),
  offset_value  DOUBLE PRECISION NOT NULL,     -- corrected = raw - offset_value
  calibrated_at TIMESTAMPTZ NOT NULL DEFAULT now(),  -- one run shares this (single txn -> one now())
  window_start  TIMESTAMPTZ,                   -- co-location window the estimate came from
  window_end    TIMESTAMPTZ,
  n_minutes     INTEGER,                        -- count of 1-minute bins in the estimate (full bins only, so shared across sensors)
  ref_kind      TEXT DEFAULT 'group-mean',      -- 'group-mean' | 'group-median' | 'reference-instrument'
  ref_group     TEXT,                           -- MACs co-located this run (for audit)
  resid_spread  DOUBLE PRECISION,               -- post-offset between-sensor spread (accept test)
  note          TEXT,
  PRIMARY KEY (sensor_id, metric, calibrated_at)
);

-- Recreate the views from scratch each apply (drop dependents first) so re-running is safe
-- even if an earlier or hand-written version had a different column shape.
DROP VIEW IF EXISTS sensor_readings_cal;
DROP VIEW IF EXISTS sensor_readings_hourly_cal;
DROP VIEW IF EXISTS sensor_offset_current;

-- Newest offset per sensor/metric (the one the calibrated views apply).
CREATE VIEW sensor_offset_current AS
SELECT DISTINCT ON (sensor_id, metric)
       sensor_id, metric, offset_value, calibrated_at
FROM sensor_calibration
ORDER BY sensor_id, metric, calibrated_at DESC;

-- Calibrated readings: raw columns preserved, *_cal added alongside so nothing existing
-- breaks. NULL offset -> raw unchanged (COALESCE 0). Each LEFT JOIN matches at most one row
-- (one offset per sensor/metric), so no row multiplication. Semantics: "latest offset
-- applies to all history" (simple + fast); for time-versioned offsets, replace each join
-- with a LATERAL picking the newest calibrated_at <= sr.time.
CREATE VIEW sensor_readings_cal AS
SELECT sr.*,
       sr.temperature - COALESCE(t.offset_value, 0) AS temperature_cal,
       sr.humidity    - COALESCE(h.offset_value, 0) AS humidity_cal,
       sr.pressure    - COALESCE(p.offset_value, 0) AS pressure_cal
FROM sensor_readings sr
LEFT JOIN sensor_offset_current t ON t.sensor_id = sr.sensor_id AND t.metric = 'temperature'
LEFT JOIN sensor_offset_current h ON h.sensor_id = sr.sensor_id AND h.metric = 'humidity'
LEFT JOIN sensor_offset_current p ON p.sensor_id = sr.sensor_id AND p.metric = 'pressure';

-- Calibrated hourly rollup: long time ranges read the continuous aggregate
-- sensor_readings_hourly (raw), so without this a long-range panel and a short-range (raw)
-- panel of the same metric disagree by the offset right at the crossover. Same offsets,
-- applied to the aggregated columns.
CREATE VIEW sensor_readings_hourly_cal AS
SELECT h.*,
       h.temp_avg     - COALESCE(t.offset_value, 0)  AS temp_avg_cal,
       h.temp_min     - COALESCE(t.offset_value, 0)  AS temp_min_cal,
       h.temp_max     - COALESCE(t.offset_value, 0)  AS temp_max_cal,
       h.hum_avg      - COALESCE(hh.offset_value, 0) AS hum_avg_cal,
       h.pressure_avg - COALESCE(p.offset_value, 0)  AS pressure_avg_cal
FROM sensor_readings_hourly h
LEFT JOIN sensor_offset_current t  ON t.sensor_id  = h.sensor_id AND t.metric  = 'temperature'
LEFT JOIN sensor_offset_current hh ON hh.sensor_id = h.sensor_id AND hh.metric = 'humidity'
LEFT JOIN sensor_offset_current p  ON p.sensor_id  = h.sensor_id AND p.metric  = 'pressure';

COMMIT;
