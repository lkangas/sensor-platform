#!/bin/bash
# Runs on FIRST database startup, after 001_schema.sql (alphabetical order).
# Creates least-privilege roles: telegraf writes readings, grafana reads everything.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE telegraf LOGIN PASSWORD '${TELEGRAF_DB_PASS}';
    GRANT USAGE ON SCHEMA public TO telegraf;
    GRANT INSERT, SELECT ON sensor_readings TO telegraf;

    CREATE ROLE grafana_ro LOGIN PASSWORD '${GRAFANA_DB_PASS}';
    GRANT USAGE ON SCHEMA public TO grafana_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
EOSQL
