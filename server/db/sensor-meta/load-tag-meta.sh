#!/usr/bin/env bash
# Load private tag metadata (names + owner/category) into the sensor_meta table.
#
# The DATA lives in a git-ignored CSV (tags.csv by default) so personal names/ownership
# never reach the public repo; this loader and the .example template are the only
# committed pieces. Idempotent: re-run any time after editing the CSV — rows are upserted
# by sensor_id, so nothing duplicates and blanks clear a field back to NULL.
#
# Run this ON THE VPS (it needs the Docker socket). Usage:
#   ./load-tag-meta.sh [path/to/tags.csv]
# Override the container if yours differs: CTR=server-timescaledb-1 ./load-tag-meta.sh
set -euo pipefail

CSV="${1:-$(dirname "$0")/tags.csv}"
CTR="${CTR:-server-timescaledb-1}"

[ -f "$CSV" ] || { echo "no CSV at: $CSV  (copy tags.example.csv -> tags.csv and fill it in)"; exit 1; }
PU=$(docker exec "$CTR" printenv POSTGRES_USER 2>/dev/null || echo postgres)
PD=$(docker exec "$CTR" printenv POSTGRES_DB   2>/dev/null || echo "$PU")

# Build one psql script: stage the CSV via inline COPY, then upsert into sensor_meta.
# tr -d '\r' tolerates a CSV saved with Windows line endings.
{
  echo "BEGIN;"
  echo "CREATE TEMP TABLE _stage (sensor_id text, name text, owner text, place text, notes text) ON COMMIT DROP;"
  echo "\\copy _stage FROM STDIN WITH (FORMAT csv, HEADER true)"
  tr -d '\r' < "$CSV"
  echo "\\."
  cat <<'SQL'
INSERT INTO sensor_meta (sensor_id, name, owner, place, notes, updated_at)
SELECT upper(trim(sensor_id)),
       nullif(trim(name),  ''),
       nullif(trim(owner), ''),
       nullif(trim(place), ''),
       nullif(trim(notes), ''),
       now()
FROM _stage
WHERE nullif(trim(sensor_id),'') IS NOT NULL
ON CONFLICT (sensor_id) DO UPDATE SET
  name       = EXCLUDED.name,
  owner      = EXCLUDED.owner,
  place      = EXCLUDED.place,
  notes      = EXCLUDED.notes,
  updated_at = now();
COMMIT;
SQL
  echo "SELECT sensor_id, coalesce(name,'—') AS name, coalesce(owner,'—') AS owner, coalesce(place,'') AS place FROM sensor_meta ORDER BY owner NULLS LAST, place NULLS FIRST, sensor_id;"
} | docker exec -i "$CTR" psql -U "$PU" -d "$PD" -v ON_ERROR_STOP=1
