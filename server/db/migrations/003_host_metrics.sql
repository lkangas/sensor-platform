-- Host/node metrics (source='host'), the fuller set beyond temperature + throttled.
-- Idempotent — apply to a live DB (init/001_schema.sql covers fresh deploys).
ALTER TABLE sensor_readings
  ADD COLUMN IF NOT EXISTS cpu_pct   DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS cpu_load1 DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS cpu_mhz   INTEGER,
  ADD COLUMN IF NOT EXISTS mem_pct   DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS disk_pct  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS core_volt DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS wifi_rssi INTEGER,
  ADD COLUMN IF NOT EXISTS power_w   DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS ssd_temp  DOUBLE PRECISION;
