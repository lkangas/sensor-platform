#!/usr/bin/env bash
# Cross-calibration: compute per-sensor correction offsets from a co-location window and
# (unless --dry-run) store them in sensor_calibration. Design: docs/local/CALIBRATION-PLAN.md
# (§2 method, §4 recalibration). Requires migration 004_calibration.sql applied.
#
# Drift-robust estimator (§2): bucket readings into 1-minute bins, keep only bins where ALL
# tags are present, average each sensor per bin, take the group reference of that bin (mean,
# or median with --ref median), and average (sensor - reference) over bins. Offsets are then
# re-centred to sum to zero (so they correct relative bias without shifting the group's
# absolute level — matters for the median path). `corrected = raw - offset`.
#
# Prints, per metric: each sensor's offset and the between-sensor spread before/after (the
# accept test — a good run collapses the spread to ~the noise floor). Then, unless --dry-run,
# INSERTs one sensor_calibration row per sensor/metric in a SINGLE transaction (all metrics
# of a run share calibrated_at and land atomically; the newest run wins via sensor_offset_current).
#
# Run ON THE VPS (needs the Docker socket), like load-tag-meta.sh. Non-interactive callers
# must pass --yes (there is no TTY to confirm at). Usage:
#   ./calibrate-offsets.sh [--metrics temperature[,pressure,humidity]] [--ref mean|median]
#                          [--dry-run] [--yes] [--note TEXT] <site> <win_start> <win_end> <MAC...>
#
# Example (placeholder MACs — your real tags + the exact command are in docs/local/CALIBRATION-PLAN.md):
#   ./calibrate-offsets.sh test '2026-07-04 15:15+03' '2026-07-05 12:54+03' \
#     AA:BB:CC:00:00:01 AA:BB:CC:00:00:02 AA:BB:CC:00:00:03 AA:BB:CC:00:00:04 AA:BB:CC:00:00:05
set -euo pipefail

METRICS="temperature"
REF="mean"
DRY=0
ASSUME_YES=0
NOTE=""
CTR="${CTR:-server-timescaledb-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --metrics) METRICS="${2:?}"; shift 2;;
    --ref)     REF="${2:?}";     shift 2;;
    --note)    NOTE="${2:?}";    shift 2;;
    --dry-run) DRY=1;            shift;;
    --yes|-y)  ASSUME_YES=1;     shift;;
    -h|--help) sed -n '2,29p' "$0"; exit 0;;
    --)        shift; break;;
    -*)        echo "unknown option: $1" >&2; exit 2;;
    *)         break;;
  esac
done

SITE="${1:?usage: calibrate-offsets.sh [opts] <site> <win_start> <win_end> <MAC...>}"; shift
WSTART="${1:?missing window_start (e.g. '2026-07-04 15:15+03')}"; shift
WEND="${1:?missing window_end}"; shift
[ "$#" -ge 2 ] || { echo "need >=2 MACs to co-calibrate against each other" >&2; exit 2; }
MACS=("$@")

# --- validate inputs (also prevents SQL injection when interpolated below) ---
[[ "$SITE" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "bad site: $SITE" >&2; exit 2; }
case "$REF" in mean|median) ;; *) echo "--ref must be mean|median" >&2; exit 2;; esac
for m in ${METRICS//,/ }; do
  case "$m" in temperature|humidity|pressure) ;; *) echo "bad metric: $m (temperature|humidity|pressure)" >&2; exit 2;; esac
done

# uppercase MACs (the DB stores colon-form upper-case) and validate the shape
mac_list=""
for i in "${!MACS[@]}"; do
  mac="$(printf '%s' "${MACS[$i]}" | tr 'a-f' 'A-F')"
  [[ "$mac" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || { echo "bad MAC: ${MACS[$i]} (want AA:BB:CC:DD:EE:FF)" >&2; exit 2; }
  MACS[$i]="$mac"
  mac_list+="${mac_list:+,}'$mac'"
done
N="${#MACS[@]}"
ref_group="$(IFS=' '; echo "${MACS[*]}")"

case "$REF" in
  mean)   REFEXPR="avg(v)";                                        REFKIND="group-mean";;
  median) REFEXPR="percentile_cont(0.5) WITHIN GROUP (ORDER BY v)"; REFKIND="group-median";;
esac

[ "$METRICS" = "${METRICS/humidity/}" ] || \
  echo "note: humidity co-location is unreliable (towel microclimate) — treat humidity offsets as provisional (CALIBRATION-PLAN §1)." >&2

DO_INSERT=$([ "$DRY" -eq 1 ] && echo 0 || echo 1)

# discover the DB user/name from the container (parity with load-tag-meta.sh)
PU=$(docker exec "$CTR" printenv POSTGRES_USER 2>/dev/null || echo postgres)
PD=$(docker exec "$CTR" printenv POSTGRES_DB   2>/dev/null || echo "$PU")

# --- confirm (only when actually inserting; guard against a non-TTY where read would EOF) ---
if [ "$DO_INSERT" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "non-interactive stdin: pass --yes to store, or --dry-run to preview." >&2; exit 2
  fi
  read -rp "Store new offsets for [$METRICS] over $WSTART..$WEND? [y/N] " ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted (nothing stored)."; exit 0;; esac
fi

# emit the SQL for one metric; $M is whitelisted, SITE/MACs/REFEXPR/N validated above.
# Values that could contain odd characters (timestamps, note) go via psql -v (:'name').
emit_metric() {
  local M="$1"
  cat <<SQL
\echo ''
\echo '=== metric: $M   (site=$SITE, ref=$REFKIND, full bins only) ==='
CREATE TEMP TABLE _binned_$M ON COMMIT DROP AS
  SELECT sensor_id, time_bucket('1 minute', time) AS bin, avg($M) AS v
  FROM sensor_readings
  WHERE site = '$SITE'
    AND time >= :'wstart'::timestamptz AND time < :'wend'::timestamptz
    AND sensor_id IN ($mac_list)
    AND $M IS NOT NULL
  GROUP BY sensor_id, bin;
-- only bins where every tag reported -> the reference is one common group anchor (§2)
CREATE TEMP TABLE _full_$M ON COMMIT DROP AS
  SELECT bin FROM _binned_$M GROUP BY bin HAVING count(*) = $N;
CREATE TEMP TABLE _dev_$M ON COMMIT DROP AS
  WITH ref AS (
    SELECT b.bin, $REFEXPR AS r
    FROM _binned_$M b JOIN _full_$M f USING (bin)
    GROUP BY b.bin
  ),
  raw AS (
    SELECT b.sensor_id, avg(b.v - ref.r) AS off, count(*) AS n_bins
    FROM _binned_$M b JOIN ref USING (bin)
    GROUP BY b.sensor_id
  )
  SELECT sensor_id, off - avg(off) OVER () AS offset_value, n_bins  -- re-centre to sum ~0
  FROM raw;
CREATE TEMP TABLE _spread_$M ON COMMIT DROP AS
  SELECT avg(s_raw) AS before, avg(s_cal) AS after FROM (
    SELECT stddev_samp(b.v) AS s_raw, stddev_samp(b.v - d.offset_value) AS s_cal
    FROM _binned_$M b JOIN _full_$M f USING (bin) JOIN _dev_$M d USING (sensor_id)
    GROUP BY b.bin) q;

\echo 'offsets (corrected = raw - offset):'
SELECT d.sensor_id,
       COALESCE(m.name, right(replace(d.sensor_id, ':', ''), 4)) AS name,
       round(d.offset_value::numeric, 4) AS offset, d.n_bins
FROM _dev_$M d LEFT JOIN sensor_meta m ON m.sensor_id = d.sensor_id
ORDER BY d.sensor_id;
\echo 'between-sensor spread (per-minute, full bins) — accept if after ~ noise floor:'
SELECT round(before::numeric,4) AS spread_before, round(after::numeric,4) AS spread_after,
       round((before/nullif(after,0))::numeric,1) AS ratio FROM _spread_$M;
\if :do_insert
INSERT INTO sensor_calibration
  (sensor_id, metric, offset_value, window_start, window_end, n_minutes, ref_kind, ref_group, resid_spread, note)
SELECT d.sensor_id, '$M', d.offset_value, :'wstart'::timestamptz, :'wend'::timestamptz,
       d.n_bins, :'refkind', :'refgroup', (SELECT after FROM _spread_$M), nullif(:'note','')
FROM _dev_$M d;
\echo '  --> $M offsets inserted.'
\endif
SQL
}

echo "Window: $WSTART -> $WEND | site=$SITE | tags($N): ${MACS[*]} | metrics: $METRICS | insert: $DO_INSERT"

# One transaction for the whole run: all metrics land atomically and share calibrated_at
# (now() is the transaction-start time), so a mid-run failure leaves nothing half-applied.
{
  echo "BEGIN;"
  for m in ${METRICS//,/ }; do emit_metric "$m"; done
  echo "COMMIT;"
} | docker exec -i "$CTR" psql -U "$PU" -d "$PD" -v ON_ERROR_STOP=1 -P pager=off \
      -v wstart="$WSTART" -v wend="$WEND" -v refkind="$REFKIND" \
      -v refgroup="$ref_group" -v note="$NOTE" -v do_insert="$DO_INSERT"

echo
if [ "$DO_INSERT" -eq 1 ]; then
  echo "done. sensor_readings_cal / sensor_readings_hourly_cal now reflect these offsets (no dashboard reload needed)."
else
  echo "dry-run complete — nothing stored. Re-run without --dry-run (and confirm) to store."
fi
