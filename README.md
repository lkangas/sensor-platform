# sensor-platform

Self-hosted stack for collecting sensor/telemetry data from multiple locations into a
single VPS, stored in **PostgreSQL + TimescaleDB** and visualized in **Grafana**. First
data source is RuuviTag environmental data; the ingestion path and schema are generic so
any future source plugs into the same contract without redesign.

See [`monitoring-platform-implementation-plan_5.md`](./monitoring-platform-implementation-plan_5.md)
for the full design and rationale.

## Design principles

1. **Dumb edge, smart centre** — edge nodes only read local sources and forward; all
   decoding, storage, and dashboards live on the VPS.
2. **A generic ingestion contract** — everyone publishes `<site>/<source>/<sensor_id>`;
   decoders republish clean values to `decoded/<site>/<source>/<sensor_id>`; Telegraf
   reads only `decoded/#` and is source-agnostic.
3. **Config as code, one repo** — this repository is the source of truth; machines *pull*.
   Per-machine differences live only in git-ignored `.env` files.
4. **One-command provisioning** — `scripts/bootstrap-edge.sh` turns a blank device into a
   live site in one run.
5. **Commit early, commit often** — history reads as a sequence of working states.

## Layout

```
server/     runs on the VPS (compose stack: mosquitto, ruuvibridge, telegraf,
            timescaledb, grafana, caddy, air-e1-decoder, fmi-weather)
edge/       runs on each edge node — Profile A (systemd binary, ARMv6) or
            Profile B (Docker, x86_64 / capable ARM)
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
| M6 — Dashboards & alerts as code | ✅ done — public Koti/Vaunu dashboards (calibrated, time-adaptive); low-battery alert fire-tested |
| M5 — First edge nodes | 📋 planned & templated — [docs/EDGE-SETUP.md](docs/EDGE-SETUP.md); awaiting hardware |
| M7, M8 | not started |

## Getting started (M0)

Confirm your RuuviTags are readable before touching any VPS or edge hardware:

```
cd scripts/test-publisher
pip install -r requirements.txt
python ruuvi_test_publisher.py
```

See [`scripts/test-publisher/README.md`](./scripts/test-publisher/README.md) for details.
