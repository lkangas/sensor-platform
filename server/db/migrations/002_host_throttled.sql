-- Host/node metrics (source='host'). SoC temperature reuses the existing 'temperature'
-- column; this adds the Raspberry Pi throttle/undervoltage bitmask from
-- `vcgencmd get_throttled` (0 = healthy; bits flag under-voltage / thermal throttling).
-- Idempotent — apply to a live DB (init/001_schema.sql covers fresh deploys).
ALTER TABLE sensor_readings ADD COLUMN IF NOT EXISTS throttled INTEGER;
