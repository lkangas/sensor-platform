-- Phase 3/M3 schema. Runs automatically on FIRST database startup (empty volume);
-- to re-run on an existing volume, apply by hand or wipe the tsdb-data volume.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE sensor_readings (
    time         TIMESTAMPTZ      NOT NULL,
    site         TEXT             NOT NULL,   -- 'home', 'summer', …
    source       TEXT             NOT NULL DEFAULT 'ruuvi', -- which pipeline/format produced this row
    sensor_id    TEXT             NOT NULL,   -- BLE MAC today; any stable per-device id in general
    sensor_name  TEXT,                        -- friendly name (RuuviBridge tag_names)
    temperature  DOUBLE PRECISION,
    humidity     DOUBLE PRECISION,
    pressure     DOUBLE PRECISION,            -- hPa (Telegraf converts from Pa)
    battery_mv   INTEGER,
    tx_power     INTEGER,
    rssi         INTEGER,
    accel_x      DOUBLE PRECISION,
    accel_y      DOUBLE PRECISION,
    accel_z      DOUBLE PRECISION,
    movement_ctr INTEGER,
    seq          INTEGER,
    -- Ruuvi Air (data format E1) — populated only for Air units, NULL for tags.
    -- Names/units confirmed against RuuviBridge parser/measurement.go + format_e1.go.
    pm1_0        DOUBLE PRECISION,   -- particulate matter <1.0 µm, µg/m³
    pm2_5        DOUBLE PRECISION,   -- PM <2.5 µm, µg/m³
    pm4_0        DOUBLE PRECISION,   -- PM <4.0 µm, µg/m³
    pm10_0       DOUBLE PRECISION,   -- PM <10 µm, µg/m³
    co2          DOUBLE PRECISION,   -- ppm
    voc          DOUBLE PRECISION,   -- VOC index (Sensirion, ~1–500, unitless)
    nox          DOUBLE PRECISION,   -- NOx index (Sensirion, ~1–500, unitless)
    lux          DOUBLE PRECISION,   -- illuminance, lux
    extras       JSONB            -- anything the fixed columns don't cover, no migration needed
);

SELECT create_hypertable('sensor_readings', 'time');
CREATE INDEX ON sensor_readings (site, sensor_id, time DESC);

-- Compress chunks older than 7 days (large space saving for append-only data)
ALTER TABLE sensor_readings SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'site, sensor_id'
);
SELECT add_compression_policy('sensor_readings', INTERVAL '7 days');

-- Drop raw rows older than 1 year (the aggregate below keeps long history cheaply)
SELECT add_retention_policy('sensor_readings', INTERVAL '365 days');

-- Hourly rollup — Grafana uses this for long time ranges
CREATE MATERIALIZED VIEW sensor_readings_hourly
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  site, sensor_id,
  avg(temperature) AS temp_avg,
  min(temperature) AS temp_min,
  max(temperature) AS temp_max,
  avg(humidity)    AS hum_avg,
  avg(pressure)    AS pressure_avg,
  min(battery_mv)  AS battery_min
FROM sensor_readings
GROUP BY bucket, site, sensor_id;

SELECT add_continuous_aggregate_policy('sensor_readings_hourly',
  start_offset      => INTERVAL '3 hours',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');
