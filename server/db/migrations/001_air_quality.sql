-- Migration 001 — Ruuvi Air (data format E1) columns
--
-- WHY THIS FILE EXISTS: init/001_schema.sql runs ONLY on first DB startup (empty
-- volume). The DB at petzval is already live, so these columns must be added to it
-- once, by hand. A fresh rebuild gets them inline from 001_schema.sql and never
-- needs this file. The two are kept in sync deliberately.
--
-- APPLY ON THE VPS (from ~/sensor-platform/server, after `git pull`):
--   docker compose exec -T timescaledb \
--     psql -U postgres -d sensors < db/migrations/001_air_quality.sql
--
-- Idempotent: ADD COLUMN IF NOT EXISTS — safe to run more than once, and harmless
-- against a fresh DB that already has the columns. Nullable, no default, so it is
-- also safe on the compressed hypertable.

ALTER TABLE sensor_readings
  ADD COLUMN IF NOT EXISTS pm1_0  DOUBLE PRECISION,  -- PM <1.0 µm, µg/m³
  ADD COLUMN IF NOT EXISTS pm2_5  DOUBLE PRECISION,  -- PM <2.5 µm, µg/m³
  ADD COLUMN IF NOT EXISTS pm4_0  DOUBLE PRECISION,  -- PM <4.0 µm, µg/m³
  ADD COLUMN IF NOT EXISTS pm10_0 DOUBLE PRECISION,  -- PM <10 µm, µg/m³
  ADD COLUMN IF NOT EXISTS co2    DOUBLE PRECISION,  -- ppm
  ADD COLUMN IF NOT EXISTS voc    DOUBLE PRECISION,  -- VOC index (~1–500)
  ADD COLUMN IF NOT EXISTS nox    DOUBLE PRECISION,  -- NOx index (~1–500)
  ADD COLUMN IF NOT EXISTS lux    DOUBLE PRECISION;  -- illuminance, lux

-- OPTIONAL, LATER — long-range rollups for air fields.
-- The hourly continuous aggregate (sensor_readings_hourly) is NOT extended here:
-- TimescaleDB can't ALTER a CAGG to add columns, so including co2/pm would mean
-- dropping and recreating it. Deferred on purpose — the raw table serves every air
-- query until multi-week ranges exist (weeks after the first Air is plugged in).
-- When you want it: drop sensor_readings_hourly, recreate it from the updated
-- definition in init/001_schema.sql with e.g. avg(co2), max(co2), avg(pm2_5) added.
