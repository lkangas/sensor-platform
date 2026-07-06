-- 006_sensor_meta_category.sql — third category axis for sensor_meta: free-form group
-- label used by dashboards to split panels WITHOUT putting tag names in the committed
-- JSON (e.g. category='cold' -> the Koti "Cold" temperature panel). Which tag belongs to
-- which category lives in the git-ignored tags.csv, so it is also rename-proof.
--
-- Apply to a live DB (init/003_sensor_meta.sql covers fresh deploys):
--   docker exec -i server-timescaledb-1 psql -U postgres -d sensors < 006_sensor_meta_category.sql
ALTER TABLE sensor_meta ADD COLUMN IF NOT EXISTS category TEXT;
