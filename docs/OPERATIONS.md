# Operations manual — "how do I…"

Task-oriented recipes for the everyday and occasional jobs this platform accumulates.
Each recipe is a few steps with exact commands. Placeholders: `vps.example.com` is your
VPS, `you` your SSH user, `AA:BB:CC:DD:EE:01` a tag MAC. Real values (host, MACs, station
ids) live in git-ignored files — see the map below and `docs/local/` on the operator's
machine.

**The one rule behind everything here:** the repo is the source of truth for *how the
system works*; git-ignored files and the database hold *what is personal* (names, MACs,
locations, credentials). Every recipe preserves that split.

## 0. The map — what lives where

| Thing | Where | Committed? |
|---|---|---|
| Stack config (compose, telegraf, mosquitto, dashboards) | `server/…` | ✅ |
| Tag names / owners / places / categories | `server/db/sensor-meta/tags.csv` → loaded into DB table `sensor_meta` | ❌ CSV is git-ignored, lives on the operator's machine |
| Weather stations (which FMI station backs which site) | `server/fmi-weather/stations.json` on the VPS | ❌ git-ignored |
| Secrets (DB/Grafana/MQTT passwords) | `server/.env` on the VPS; MQTT users in `server/mosquitto/passwd` | ❌ |
| Calibration offsets | DB table `sensor_calibration` (runbook: `docs/local/CALIBRATION-PLAN.md`) | ❌ (mechanism ✅: migration 004 + `scripts/calibrate-offsets.sh`) |
| Measurement data | TimescaleDB `sensor_readings` (+ `sensor_readings_1min`/`_hourly` aggregates) | — |
| Personal runbooks / real constants | `docs/local/` | ❌ git-ignored |

Deploying config = `git push`, then on the VPS `git pull` + the restart listed in §8.

## 1. Rename a tag (or change owner/place/category/notes)

Names live in the DB (`sensor_meta`), joined at query time — so a rename relabels **all
history instantly**, needs no dashboard edits, and never touches the public repo.

1. On the operator's machine, edit `server/db/sensor-meta/tags.csv`
   (columns: `sensor_id,name,owner,place,category,notes`).
2. Copy it to the VPS and load (idempotent upsert; the CSV never stays on the VPS):
   ```bash
   scp server/db/sensor-meta/tags.csv you@vps.example.com:/tmp/tags.csv
   ssh you@vps.example.com "cd ~/sensor-platform && ./server/db/sensor-meta/load-tag-meta.sh /tmp/tags.csv && rm /tmp/tags.csv"
   ```
3. Refresh the dashboard. Done — calibration offsets are keyed on the MAC and are
   unaffected by renames.

**Add a new tag:** same recipe — add a CSV row. Data flows in automatically as soon as a
gateway hears the MAC, and an **unlisted tag auto-appears on the board of the site that
hears it** (home site → Koti, summer site → Vaunu), labelled with the last 4 MAC chars.
The CSV row upgrades it: a name, the right board via `place` (regardless of which site
hears it), or `owner=other` to move a stray to the "other" board instead. All history
relabels/moves retroactively.

## 2. Group tags into their own panel (the `category` axis)

`category` in `tags.csv` is a free-form panel-grouping label. Example: `cold` puts a
fridge/freezer tag on the Koti **Cold** temperature panel and removes it from the main
Temperature panel. Set the cell, run the loader (§1) — no dashboard edit, survives
renames. New categories need a matching panel filter (`m.category = '<label>'`) — copy
the Cold panel's SQL shape.

## 3. Calibrated vs raw values

Per-sensor offsets (from co-location runs) are applied **at query time** — raw data is
never modified. `corrected = raw − offset`. The Koti board has a **Values:
Calibrated | Raw** dropdown; other boards show calibrated only.

**Re-run a calibration** (after adding/replacing a tag, or to improve an estimate):
co-locate the tags for some hours, then on the VPS:

```bash
cd ~/sensor-platform
./scripts/calibrate-offsets.sh --metrics temperature --dry-run <site> "<start>" "<end>" <MAC> <MAC> …
# review offsets + accept-test spread, then re-run with --yes to store
```

New offsets take effect immediately and retroactively (query-time). History of every run
stays in `sensor_calibration`. Full runbook with real MACs: `docs/local/CALIBRATION-PLAN.md`.

## 4. Reading the dashboards (why zoom changes resolution)

Panels are **time-adaptive**: windows ≤ 3 h read raw data (every beacon, ~1–3 s), longer
windows read a pre-computed 1-minute aggregate (fast at any range). Drag-select any sub-3h
region to get full resolution for it. The crossover is the literal `10800` (seconds) in
each panel's SQL. The dashed grey line on Temperature panels is the nearest FMI weather
station (10-min cadence — that's FMI's, not ours).

**Editing dashboards:** edit in the browser, then pull the JSON back into git
(`scripts/grafana-pull-dashboard.sh <uid>`) — a UI save alone is lost on rebuild. Keep
panel SQL in raw mode and preserve both `UNION ALL` branches or long windows go slow.
Details: `server/grafana/README.md`.

## 5. Weather stations (FMI)

Config: `server/fmi-weather/stations.json` **on the VPS** (git-ignored;
`stations.example.json` shows the format — site, display label, `fmisid`, parameters).
Find a station's `fmisid` at https://en.ilmatieteenlaitos.fi/observation-stations.

- **Add/change a station:** edit the file, then `docker compose restart fmi-weather`
  (run compose commands from `~/sensor-platform/server`).
- **Backfill history:**
  ```bash
  docker exec server-fmi-weather-1 python backfill.py 7 \
    | docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1
  ```
  then refresh the aggregate so long views show it:
  `CALL refresh_continuous_aggregate('sensor_readings_1min', now()-interval '8 days', now()-interval '2 minutes');`
- More metrics: add `"humidity"`/`"pressure"` to a station's `parameters` — no schema
  change needed.

## 6. Health checks

```bash
ssh you@vps.example.com
cd ~/sensor-platform/server
docker compose ps                       # everything Up? (timescaledb shows "healthy")
docker compose logs --since 10m telegraf | grep -E "E!|error"   # ingest errors?
docker compose logs --since 15m fmi-weather | tail              # weather poller alive?
```

Data actually flowing (rows in the last 10 min, by stream):

```bash
docker exec -i server-timescaledb-1 psql -U postgres -d sensors -c \
 "SELECT site, source, count(*) FROM sensor_readings WHERE time > now()-interval '10 min' GROUP BY 1,2 ORDER BY 3 DESC"
```

Rough expectations: tags ≈ one row per ~1–4 s each (dedupe removes re-broadcasts, so
quiet Air-class devices legitimately produce fewer rows); host metrics ~30 s; FMI one row
per 10 min per station.

## 7. Backup / restore the private bits

A `git clone` restores everything **except**: `server/.env`, `server/mosquitto/passwd`
(VPS), `server/db/sensor-meta/tags.csv` (operator's machine),
`server/fmi-weather/stations.json` (VPS), `docs/local/`. Keep copies of these in a
password manager / private store, and refresh the copy whenever one changes.
The measurement database itself: `pg_dump` off-VPS is planned under M8 (plan §11) — until
that lands, the DB is unbacked-up.

**Restore from scratch:** clone the repo on the VPS → restore `.env`, `passwd`,
`stations.json` → `docker compose up -d` (init SQL creates the schema) → apply
`server/db/migrations/*.sql` in order → load `tags.csv` (§1) → re-store calibration
offsets (§3 history, or re-run).

## 8. Deploying changes — what needs a restart?

| You changed | Then |
|---|---|
| Dashboard JSON | nothing — Grafana hot-reloads within ~30 s of `git pull` |
| `telegraf/telegraf.conf` | `docker compose restart telegraf` (seconds-long ingest gap) |
| `fmi-weather/` code or `stations.json` | `docker compose up -d --build fmi-weather` / `restart fmi-weather` |
| `docker-compose.yml` | `docker compose up -d` (recreates only changed services) |
| A new `db/migrations/NNN_*.sql` | apply by hand: `docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1 < server/db/migrations/NNN_….sql` — migrations are **not** auto-run |
| `mosquitto/` config or ACL | `docker compose restart mosquitto` |
| `tags.csv` / calibration | nothing — both are query-time (DB contents, not services) |

## 9. Committing — the hygiene gate

This repo is **public**. Before every commit, check the staged diff *and the commit
message you're about to write* for personal identifiers: real tag names, hostnames,
MAC addresses, station names/ids, or wording that reveals whose sensors are observed.
Genericise ("a tag in range", "owner=other", "an edge node") or keep the detail in a
git-ignored file. Describing a redaction by naming the redacted thing defeats it —
commit messages are as public as the files.
