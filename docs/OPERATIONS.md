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
| Edge publishers (BLE gateway, host metrics, Hue, SSH monitor) | `edge/…` code; per-node `.env` / `/etc/ssh-monitor.env` | ✅ code; ❌ the per-node `.env` secrets |
| Tag names / owners / places / categories | `server/db/sensor-meta/tags.csv` → loaded into DB table `sensor_meta` | ❌ CSV is git-ignored, lives on the operator's machine |
| Weather stations (which FMI station backs which site) | `server/fmi-weather/stations.json` on the VPS | ❌ git-ignored |
| Secrets (DB/Grafana/MQTT passwords; Hue key) | `server/.env` on the VPS; MQTT users in `server/mosquitto/passwd`; edge `.env` per node | ❌ |
| Calibration offsets | DB table `sensor_calibration` (runbook: `docs/local/CALIBRATION-PLAN.md`) | ❌ (mechanism ✅: migration 004 + `scripts/calibrate-offsets.sh`) |
| Measurement data | TimescaleDB `sensor_readings` (+ `sensor_readings_1min`/`_hourly` aggregates) | — |
| Personal runbooks / real constants | `docs/local/` | ❌ git-ignored |

The platform ingests **six sources** into the one `sensor_readings` table, told apart by
the `source` tag: `ruuvi` (tags + Air), `host` (node self-health), `fmi` (weather),
`hue` (Philips Hue), `security` (SSH exposure). Recipes for each are below.

Deploying config = `git push`, then on the VPS `git pull` + the restart listed in §10.

## 1. Rename a tag (or change owner/place/category/notes)

Names live in the DB (`sensor_meta`), joined at query time — so a rename relabels **all
history instantly**, needs no dashboard edits, and never touches the public repo.

1. On the operator's machine, edit `server/db/sensor-meta/tags.csv`
   (columns: `sensor_id,name,owner,place,category,notes`). Standard CSV rules: quote any
   field that contains a comma (`…,other,,,"first seen 2026-07-04, listed 2026-07-06"`),
   or the loader rejects the row with "extra data after last expected column".
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

There are six boards: **Koti** (home), **Vaunu** (summer), **Perf** (host metrics),
**Security** (SSH exposure), **Hue** (temporary triage board), and an "other" board
(VPS-only). All source their panels from `sensor_readings` filtered by `source`/`place`.

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

## 6. Philips Hue (motion, buttons, light state)

The **home edge node** runs the Hue collector (`edge/hue-collector/`, `source='hue'`): it
streams the bridge's CLIP v2 server-sent events and logs **motion** (`motion` 0/1),
**remote-button presses** (`event`, e.g. `b2:short_release`), the motion sensors'
**temperature / lux / battery** (`battery_pct`), and — with `LOG_LIGHTS=1` (the default) —
every light's **on/off** (`on_state` 0/1), **brightness** and **colour temperature**
(`mirek`). One `sensor_id` per physical device, like a RuuviTag's metrics.

- **Config** lives in the collector's git-ignored `.env`: bridge LAN IP + `HUE_KEY`
  (the pairing application key — a credential), the site MQTT creds, and
  `SNAPSHOT_INTERVAL` (default 900 s, the continuous-metrics heartbeat). Install / redeploy
  steps and the required server-side pieces: `edge/hue-collector/README.md`.
- **Quieten it:** set `LOG_LIGHTS=0` in the `.env` and restart the collector — light state
  is chatty (hundreds of events/min under dynamic scenes); motion and buttons stay logged.
- `motion`/`event` are point-in-time rows — query raw, don't average (the 1-min aggregate
  ignores them by design). Device names flow into `sensor_name` (DB only, like tag names —
  never the repo).

## 7. SSH-exposure monitor (security)

Any node with its SSH port exposed can run the monitor (`edge/ssh-monitor/`,
`source='security'`): a **root** systemd service that each interval
(`SSH_MONITOR_INTERVAL`, default 60 s) publishes how much SSH traffic it sees —
`ssh_failed` (bad-password attempts), `ssh_accepted` (real logins), `ssh_ips` (distinct
attacking IPs), and fail2ban's `f2b_banned` / `f2b_banned_total`. It reads journald and
`fail2ban-client`, both root-only — hence the root service. One row per node per interval.

- **Install:** `edge/ssh-monitor/README.md` (copy the script to `/usr/local/bin`, install
  the env to `/etc/ssh-monitor.env` from the site's `edge/.env`, enable the unit). View it
  on the **Security** dashboard.
- The `f2b_*` gauges need fail2ban installed on the node (they read 0 without it).
- Baseline before you expose a port is all zeros bar your own `ssh_accepted`; the failed /
  IP / ban curves only climb once the port is actually reachable from the internet.

## 8. Health checks

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

Rough expectations by `source`: `ruuvi` ≈ one row per ~1–4 s each (dedupe removes
re-broadcasts, so quiet Air-class devices legitimately produce fewer); `host` ~30 s;
`fmi` one row per 10 min per station; `hue` bursty/event-driven with a snapshot heartbeat
every `SNAPSHOT_INTERVAL` (~15 min); `security` one row per node per `SSH_MONITOR_INTERVAL`
(~1 min). Hue and security are edge-node services — if their rows stop, check the service
on the node (`journalctl -u ssh-monitor` / the Hue collector), not the VPS.

## 9. Backup / restore the private bits

A `git clone` restores everything **except**: `server/.env`, `server/mosquitto/passwd`
(VPS), `server/db/sensor-meta/tags.csv` (operator's machine),
`server/fmi-weather/stations.json` (VPS), `docs/local/`, and the **per-node edge secrets**
— the Hue collector's `.env` (holds `HUE_KEY`) and each node's `/etc/ssh-monitor.env`.
Keep copies of these in a password manager / private store, and refresh the copy whenever
one changes. The measurement database itself: `pg_dump` off-VPS is planned under M8
(plan §11) — until that lands, the DB is unbacked-up.

**Restore from scratch:** clone the repo on the VPS → restore `.env`, `passwd`,
`stations.json` → `docker compose up -d` (init SQL creates the schema) → apply
`server/db/migrations/*.sql` in order — **each column-adding migration needs the view
dance (§10), and a naive "in order" run errors without it** → load `tags.csv` (§1) →
re-store calibration offsets (§3 history, or re-run) → redeploy the edge publishers
(their per-node `.env` restored from the private store).

## 10. Deploying changes — what needs a restart?

| You changed | Then |
|---|---|
| Dashboard JSON | nothing — Grafana hot-reloads within ~30 s of `git pull` |
| `telegraf/telegraf.conf` | `docker compose restart telegraf` (seconds-long ingest gap) |
| `fmi-weather/` code or `stations.json` | `docker compose up -d --build fmi-weather` / `restart fmi-weather` |
| `docker-compose.yml` | `docker compose up -d` (recreates only changed services) |
| A new `db/migrations/NNN_*.sql` | apply by hand (migrations are **not** auto-run): `docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1 < server/db/migrations/NNN_….sql`. If it `ADD COLUMN`s to `sensor_readings`, do the **view dance** below. |
| `mosquitto/` config or ACL | `docker compose restart mosquitto` |
| An `edge/…` publisher | redeploy on the node, not the VPS (per that publisher's README) |
| `tags.csv` / calibration | nothing — both are query-time (DB contents, not services) |

**The "004 view dance"** — any migration that adds a column to `sensor_readings` (007,
008, 009 all did) must re-run `004_calibration.sql` so the calibrated view surfaces the new
column, because `sensor_readings_cal` is `SELECT sr.*` and freezes its column list at
CREATE time. But 004 drops `sensor_offset_current`, which 005's `sensor_readings_1min_cal`
depends on — so the order matters. After applying `NNN_*.sql`:

1. `DROP VIEW IF EXISTS sensor_readings_1min_cal;`
2. re-apply `004_calibration.sql`
3. re-run the `CREATE OR REPLACE VIEW sensor_readings_1min_cal …` block from
   `005_onemin_aggregate.sql`

Each such migration's own header repeats these steps. Skip the dance and the new column
simply never appears in `sensor_readings_cal`; run a naive "apply in order" restore and it
**errors**, because re-applying 004 fails while the 1min_cal view still references the
view 004 is about to drop.

## 11. Committing — the hygiene gate

This repo is **public**. Before every commit, check the staged diff *and the commit
message you're about to write* for personal identifiers: real tag names, hostnames,
MAC addresses, station names/ids, or wording that reveals whose sensors are observed.
Genericise ("a tag in range", "owner=other", "an edge node") or keep the detail in a
git-ignored file. Describing a redaction by naming the redacted thing defeats it —
commit messages are as public as the files.
