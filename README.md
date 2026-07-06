# sensor-platform

Self-hosted stack for collecting sensor/telemetry data from multiple locations into a
single VPS, stored in **PostgreSQL + TimescaleDB** and visualized in **Grafana**. The
ingestion path and schema are generic, so every source lands in one `sensor_readings`
table told apart by a `source` tag. Six sources flow today: **ruuvi** (RuuviTag + Ruuvi
Air over BLE), **host** (per-node self-health), **fmi** (open weather), **hue** (Philips
Hue motion/buttons/light state), and **security** (SSH-exposure / fail2ban counters).

See [`monitoring-platform-implementation-plan_5.md`](./monitoring-platform-implementation-plan_5.md)
for the full design and rationale.

## Design principles

1. **Dumb edge, smart centre** — edge nodes only read local sources and forward; all
   decoding, storage, and dashboards live on the VPS.
2. **A generic ingestion contract** — everyone publishes `<site>/<source>/<sensor_id>`.
   Sources that need decoding republish clean values to `decoded/<site>/<source>/<sensor_id>`
   (RuuviBridge, the FMI poller); sources that already emit clean values (host, Hue,
   security) publish straight to `<site>/<source>/<sensor_id>`. Telegraf maps the topic
   segments to `site`/`source`/`sensor_id` and is source-agnostic.
3. **Config as code, one repo** — this repository is the source of truth; machines *pull*.
   Per-machine differences live only in git-ignored `.env` files.
4. **One-command provisioning** — `scripts/bootstrap-edge.sh` turns a blank device into a
   live site in one run.
5. **Commit early, commit often** — history reads as a sequence of working states.

## Layout

```
server/     runs on the VPS (compose stack: mosquitto, ruuvibridge, telegraf,
            timescaledb, grafana, caddy, air-e1-decoder, fmi-weather)
edge/       runs on each edge node — the BLE forwarder (Profile A systemd binary /
            Profile B Docker gateway / Profile C BlueZ-cooperative publisher) plus
            optional publishers: host-metrics, hue-collector, ssh-monitor, watchdog
scripts/    bootstrap-edge.sh + test-publisher/ (Phase 0 local verification)
ansible/    optional fleet management (3+ nodes)
```

## Status

| Milestone | State |
|-----------|-------|
| M0 — Verified data source (Phase 0 test script) | ✅ done — 6 tags read live (DF5) |
| M1 — Foundation (VPS hardened, Docker, DNS) | ✅ done — vps.example.com → Hetzner hel1 |
| M2 — Server up (stack healthy, HTTPS) | ✅ done — https://vps.example.com + MQTTS 8883 |
| M3 — Schema live (hypertable + caggs) | ✅ done — sensor_readings + hourly & 1-min rollups + query-time calibration |
| M4 — Glue proven (publish → decode → DB) | ✅ done — 8 tags, 37 rows on first run |
| M5 — First edge nodes | ✅ done — two sites live and forwarding ([docs/EDGE-SETUP.md](docs/EDGE-SETUP.md)) |
| M6 — Dashboards & alerts as code | ✅ done — five committed boards (Koti/Vaunu calibrated + time-adaptive, Perf, Security, Hue) + a VPS-only "other"; low-battery alert fire-tested |
| M7 — Repeatable edge (bootstrap) | 🟡 script committed, not yet proven on a blank device |
| M8 — Fleet & extras | 🟡 partial — second site ✅, FMI weather ✅, Hue ✅, SSH-exposure monitor ✅; backups + fleet tooling pending |
| M9 — Operator's user manual | ✅ done — [docs/OPERATIONS.md](docs/OPERATIONS.md) (+ git-ignored real-values quickref), operator-reviewed |

## Getting started (M0)

Confirm your RuuviTags are readable before touching any VPS or edge hardware:

```
cd scripts/test-publisher
pip install -r requirements.txt
python ruuvi_test_publisher.py
```

See [`scripts/test-publisher/README.md`](./scripts/test-publisher/README.md) for details.
