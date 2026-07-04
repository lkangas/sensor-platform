# Home & Remote Sensor Monitoring Platform — Implementation Plan

A self-hosted stack for collecting sensor and telemetry data from multiple locations into
a single VPS, stored in **PostgreSQL + TimescaleDB** and visualized in **Grafana**. The
first data source is RuuviTag environmental data, but the pipeline is designed so that
any future data source — a different sensor type, a different protocol, a different
edge device — plugs into the same ingestion path and schema without redesigning either.

The plan is built around four principles that keep it easy to grow:

1. **Dumb edge, smart centre.** Each edge node does one job — read its local
   source(s) and forward data. All decoding, storage, and dashboards live on the VPS.
   Adding a new site or source never means touching the central pipeline's design.
2. **A generic ingestion contract, not a source-specific one.** Every source publishes
   into the same topic/schema convention (site, source type, sensor identifier,
   timestamp, values). The pipeline doesn't need to know in advance what kinds of
   sensors will exist — decoding a specific source's wire format is an isolated,
   swappable step, not something baked into storage or dashboards.
3. **Config as code, in one Git repo.** Every compose file, config, schema, and script
   lives in a single repository that is the source of truth. Machines *pull* from it;
   nothing is hand-configured in place.
4. **One-command provisioning.** A new edge node goes from blank device to sending data
   by running a single bootstrap script (later: one Ansible command for the whole
   fleet).
5. **Commit early, commit often.** The Git repo (principle 3) is created at the very
   start of implementation, before any other work — and every time a piece reaches a
   genuinely working state (a checkpoint in this plan passes, a service comes up
   healthy, a script produces correct output), that gets committed immediately rather
   than batched into a larger commit later. The history should read as a sequence of
   working states, so any point in the build can be returned to cleanly.

---

## 0. Architecture

```
  SITE A (home)                 SITE B (summer place)          SITE C (…)
  ┌──────────────┐              ┌──────────────┐               ┌──────────────┐
  │ Local source │  (BLE, etc.) │ Local source │  (BLE, etc.)  │ Local source │
  │      ↓       │              │      ↓       │               │      ↓       │
  │  Edge node   │              │  Edge node   │               │  Edge node   │
  │ (reads+fwds) │              │ (reads+fwds) │               │ (reads+fwds) │
  └──────┬───────┘              └──────┬───────┘               └──────┬───────┘
         │  MQTT over TLS (8883), per-site username + topic prefix    │
         └───────────────────────────┬───────────────────────────────┘
                                      ▼
                         ┌─────────────────────────┐
                         │           VPS            │
                         │                          │
                         │  Mosquitto (MQTT broker) │  raw <site>/<source>/… topics
                         │            ↓             │
                         │  Source decoder(s)       │  format-specific: raw → clean values
                         │            ↓             │  republishes to a common topic shape
                         │  Telegraf (mqtt→sql)     │  writes rows
                         │            ↓             │
                         │  PostgreSQL + TimescaleDB│  hypertable + continuous aggregates
                         │            ↑             │
                         │  Grafana (dashboards)    │
                         │            ↑             │
                         │  Caddy (auto-HTTPS)      │  :443 → Grafana (or a shared
                         │                          │  reverse proxy if co-hosting
                         │                          │  with another app — see Phase 1/2)
                         └─────────────────────────┘
```

**The topic convention is the actual contract.** Every publisher — whatever it is —
writes to `<site>/<source>/<sensor_id>` for raw data. A source-specific decoder (if the
raw format needs translating) republishes clean values to a matching
`decoded/<site>/<source>/<sensor_id>` topic, always in the same flat key/value shape.
Telegraf only ever reads from the `decoded/#` namespace and doesn't care what produced
it. This means onboarding a new kind of source later is two isolated changes — add its
decoder (or have it publish already-decoded values directly, skipping that step) and
give it a `source` name — with no changes to storage, Telegraf, or dashboards.

**Why a decoder *and* Telegraf, rather than one piece?** For RuuviTag data specifically,
RuuviBridge understands the Bluetooth manufacturer format and turns raw hex into
temperature/humidity/pressure/etc., but its database output targets InfluxDB, not
Postgres. So RuuviBridge decodes and republishes clean measurements to MQTT, and Telegraf
(which has a first-class PostgreSQL output) writes those into TimescaleDB. Any other
source that needs format-specific decoding follows the same shape: a small decoder step,
then the same shared Telegraf → Postgres path. Sources that already publish clean
values don't need a decoder step at all — they just need to speak the same topic/value
convention. If you'd rather run one container instead of two for the current source, you
can replace both with a small MQTT→Postgres consumer — noted as an alternative in
Phase 4.

**Component reference**

| Component        | Role                                       | Image (verify current tag) | Where |
|------------------|---------------------------------------------|----------------------------|-------|
| ruuvi-go-gateway | BLE scan + forward raw (edge, current source)| `ghcr.io/scrin/ruuvi-go-gateway` | Each edge node |
| Mosquitto        | MQTT broker / ingestion point              | `eclipse-mosquitto`        | VPS |
| RuuviBridge      | Decode Ruuvi format, republish clean       | `ghcr.io/scrin/ruuvibridge`| VPS |
| Telegraf         | MQTT consumer → Postgres writer (source-agnostic) | `telegraf`           | VPS |
| TimescaleDB      | Time-series storage (Postgres ext.)        | `timescale/timescaledb:latest-pg16` | VPS |
| Grafana          | Dashboards & alerting                      | `grafana/grafana`          | VPS |
| Caddy            | Reverse proxy + automatic TLS (own, or shared if co-hosting — Phase 1/2) | `caddy` | VPS |

Docs: [ruuvi-go-gateway](https://github.com/Scrin/ruuvi-go-gateway) ·
[RuuviBridge](https://github.com/Scrin/RuuviBridge) ·
[RuuviBridge sample config](https://github.com/Scrin/RuuviBridge/blob/master/config.sample.yml) ·
[TimescaleDB](https://www.tigerdata.com/timescaledb) ·
[Ruuvi private-server guide](https://ruuvi.com/connecting-ruuvi-gateway-to-a-private-server/)

---

## 1. Prerequisites — decisions to lock before building

- [ ] **VPS — fresh or shared, decide up front.** Two valid paths:
      - **Fresh, dedicated VPS.** 2 vCPU / 4 GB RAM, ~40 GB disk, Ubuntu 24.04 LTS
        (Hetzner CX23, or equivalent on any provider) — this runs the whole stack
        comfortably with headroom, and every phase below is written for this case by
        default.
      - **An existing VPS already running another app.** Workable, but that other app's
        Caddy/reverse-proxy and resource footprint become constraints this plan has to
        route around rather than assume away — see the "if sharing a host" notes in
        Phase 1 and Phase 2. If you go this way, expect to budget TimescaleDB's memory
        explicitly rather than trust defaults sized for a dedicated box, and to decide
        which app's Caddy instance is canonical (only one process can bind 80/443).
      Either way, Hetzner's shared-vCPU plans resize vertically with minimal downtime if
      you later need more room — cheap insurance either path.
- [ ] **Domain name.** A subdomain pointed at the VPS (e.g. `metrics.example.com`) so
      Caddy can obtain Let's Encrypt certificates automatically. Needed for HTTPS on
      Grafana and for TLS on the MQTT listener.
- [ ] **Edge hardware, per site.** You don't need matching hardware at every site — the
      edge role is light enough (scan BLE, forward MQTT) that almost anything works.
      Broadly, two tiers:
      - **Any x86_64 machine, or an ARMv7/ARMv8 Pi (3-series or better).** These are
        capable enough to run the standard Docker-based edge profile (Phase 5, Profile
        B) — no special handling needed, just install Linux and Docker as usual.
      - **An older ARMv6 board (e.g. original Pi Zero W, Pi 1).** Docker is the fragile
        path here — many container images don't publish an `arm/v6` variant — so these
        use a lighter native-binary/systemd profile instead (Phase 5, Profile A).
      Buying notes if you're adding sites later:
        - Boards themselves are generally available again, but a DRAM-price spike tied
          to AI-driven memory demand has pushed *new* Pi prices up through 2026
          (notably the Pi 5). This project needs almost no RAM, so aim low on the
          lineup rather than buying the newest board.
        - **Pi 3-series boards** (3B/3B+/3A+) are good targets — Cortex-A53/ARMv8,
          built-in Bluetooth, Docker-capable (Profile B). 3A+ has no Ethernet and only
          512MB RAM, both fine for this role.
        - **Pi 2B** has no Bluetooth on any revision — needs a USB BLE dongle if used.
          Its 64-bit-capable revision (v1.2) still counts as Profile B; the 32-bit-only
          v1.1 does not need Profile A either — v1.1 is ARMv7, not ARMv6.
        - **Pi Zero 2 W** is spec-wise ideal (small, Wi-Fi+BT, Docker-capable) but
          currently hard to find in stock — don't plan around getting one quickly.
        - The **used market** is a good option since this role doesn't need a pristine
          board. `rpilocator.com` tracks new stock across resellers if buying new.
      - Whatever the board, use a good microSD card (A1/A2) and a known-good power
        supply — undervoltage causes flaky Wi-Fi/Bluetooth, especially bad at a remote
        site.
- [ ] **RuuviTags.** You have these. Note each tag's MAC address; you'll map MACs to
      friendly names later.
- [ ] **Git repository.** GitHub (private) or self-hosted. Create this **first**, before
      Phase 0 — the local verification script goes into it too, and every subsequent
      working checkpoint gets committed as it's reached, not batched up later.
- [ ] **A password manager / secrets store** for the credentials you'll generate
      (Postgres password, Grafana admin, per-site MQTT users).

---

## 2. Repository layout

Create this once. Every machine clones it; per-machine differences live only in `.env`
files (which are **git-ignored**).

```
sensor-platform/
├── server/                        # runs on the VPS
│   ├── docker-compose.yml
│   ├── .env.example               # template; real .env is git-ignored
│   ├── caddy/Caddyfile            # own instance by default; if co-hosting with
│   │                              #   another app, this becomes a site-block snippet
│   │                              #   merged into whichever Caddyfile is canonical
│   ├── mosquitto/
│   │   ├── mosquitto.conf
│   │   └── acl                    # per-site topic permissions
│   ├── ruuvibridge/config.yml
│   ├── telegraf/telegraf.conf
│   ├── grafana/provisioning/      # datasources + dashboards as code
│   └── db/init/001_schema.sql     # runs on first DB startup
│
├── edge/                          # runs on each edge node (two profiles, see Phase 5)
│   ├── docker-compose.yml         # Profile B: Docker (x86_64 / capable ARM boards)
│   ├── .env.example
│   ├── ruuvi-go-gateway/config.yml
│   ├── bin/                       # Profile A: prebuilt binaries per architecture
│   │   └── ruuvi-gateway-armv6l
│   └── systemd/ruuvi-gateway.service  # Profile A: systemd unit
│
├── scripts/
│   ├── bootstrap-edge.sh          # one-command edge node setup
│   └── test-publisher/            # Phase 0: temporary local script, not a real edge
│       └── ruuvi_test_publisher.py    # node — Windows/WSL, scans + publishes to MQTT
│
├── ansible/                       # optional, for 3+ edge nodes
│   ├── inventory.ini
│   ├── provision-edge.yml
│   └── host_vars/                 # per-node site name + secrets (vault-encrypted)
│
├── .gitignore                     # ignore **/.env, secrets, certs
└── README.md
```

---

## Phase 0 — Local verification script (start here)

Goal: confirm RuuviTag data can actually be read, before any VPS or edge hardware is
involved. Runs on the Windows machine you already have with Bluetooth — in WSL if
convenient, but plain Windows works too since the library involved is cross-platform.

This is explicitly a **throwaway script, not a real edge node** — it doesn't get a
Docker profile or a permanent home in the fleet; it exists to de-risk the "can I even
read my tags" question early and cheaply, and later to smoke-test the ingestion pipeline
once the VPS exists. It still lives in the repo (`scripts/test-publisher/`) and gets
committed once it works, per the commit-early principle above — it's just not part of
the deployed system.

1. **Read-only first.** A small Python script using `bleak` (cross-platform BLE
   library, works natively on Windows) that scans for RuuviTag advertisements and
   decodes them — either by hand for Data Format 5, or via the `ruuvitag_sensor`
   package, which already knows the Ruuvi formats — and just prints readings to the
   console. No MQTT, no VPS dependency. This alone answers "do I get RuuviTag data."
2. **Add MQTT publishing once the VPS exists (Phase 2+).** Extend the same script with
   `paho-mqtt` to publish into the same topic convention a real gateway would use
   (`<site>/ruuvi/<sensor_id>`, using a site name like `test`), pointed at the VPS's
   Mosquitto broker. This exercises the entire pipeline — decoding, Telegraf, the
   schema, Grafana — without needing any real edge hardware yet, and is a natural
   checkpoint for Phase 4.
3. Run manually when needed; this isn't meant to run unattended or persistently — it's
   a verification tool you reach for during testing, not a service.

**Checkpoint:** the script prints readable temperature/humidity/pressure values from
your actual RuuviTags. This is the real starting point for implementation — everything
else in this plan follows once this works.

---

## 3. Phase 1 — VPS base setup

Goal: a hardened host with Docker, reachable over HTTPS.

- [ ] Create the VPS with your SSH key; log in as root once. *(If sharing an existing
      host instead: skip this — the box, user, SSH hardening, and Docker are presumably
      already in place; confirm rather than re-do them.)*
- [ ] Create a non-root sudo user; disable root SSH and password auth in
      `/etc/ssh/sshd_config` (`PermitRootLogin no`, `PasswordAuthentication no`).
- [ ] `ufw` firewall — allow only what's needed:
      - `22/tcp` (SSH)
      - `443/tcp` (HTTPS)
      - `8883/tcp` (MQTT over TLS)
      - deny everything else. **Postgres (5432), Grafana (3000), and plain MQTT (1883)
        are never exposed** — they stay on the internal Docker network.
      *(If sharing an existing host: `443` is presumably already open for the other
      app — this stack only adds `8883`, not a duplicate `443` rule.)*
- [ ] Install `fail2ban` and enable `unattended-upgrades`.
- [ ] Install Docker Engine + the Compose plugin (official convenience script or apt repo).
- [ ] Point the DNS **A record** for your subdomain at the VPS IP.
- [ ] **If sharing an existing host:** one more decision before Phase 2 — only one
      process can bind ports 80/443. This stack's Caddy must not also try to bind them;
      either fold this stack's site block into the other app's existing Caddyfile, or
      migrate the other app's site block into this stack's Caddyfile instead. Pick which
      Caddyfile is canonical now, since Phase 2's compose file differs depending on the
      answer.

**Checkpoint:** `docker run --rm hello-world` works; `dig metrics.example.com` returns the
VPS IP. *(If sharing a host: also confirm the existing app is still reachable and
unaffected.)*

---

## 4. Phase 2 — Core server stack

Goal: the full stack running from one `docker compose up`, reachable over HTTPS.

`server/docker-compose.yml` defines six services on a shared network:

```yaml
services:
  timescaledb:      # timescale/timescaledb:latest-pg16
    # volume for data; mounts db/init/*.sql (runs once on first boot)
    # NOT published to host — internal only
  mosquitto:        # eclipse-mosquitto
    # ports: 8883 (TLS) published; 1883 internal only
    # mounts mosquitto.conf + acl + TLS cert from Caddy's volume
  ruuvibridge:      # ghcr.io/scrin/ruuvibridge
    # mounts ruuvibridge/config.yml; listens on internal mosquitto, republishes decoded
  telegraf:         # telegraf
    # mounts telegraf.conf; reads decoded MQTT → writes timescaledb
  grafana:          # grafana/grafana
    # mounts provisioning/; internal only (Caddy fronts it)
  caddy:            # caddy
    # ports: 443 (and 80 for ACME); reverse-proxies grafana; auto-TLS
    # SKIP this service entirely if sharing a host and joining an existing
    #   Caddy instead — see below
```

Key points:
- Secrets (`POSTGRES_PASSWORD`, `GF_SECURITY_ADMIN_PASSWORD`, MQTT creds) come from
  `server/.env`, referenced as `${VAR}` in the compose file.
- Every service gets `restart: unless-stopped`.
- `caddy/Caddyfile` is tiny:
  ```
  metrics.example.com {
      reverse_proxy grafana:3000
  }
  ```
  Caddy fetches and renews the certificate automatically. Point Mosquitto's TLS listener
  at the same certificate (shared volume) so the MQTT endpoint is also properly
  encrypted.
- Grafana: set `GF_USERS_ALLOW_SIGN_UP=false` and change the admin password on first
  login.

**If sharing an existing host (skip the `caddy` service above):** add this stack's site
block to whichever Caddyfile you decided is canonical in Phase 1, e.g.:
  ```
  metrics.example.com {
      reverse_proxy grafana:3000
  }
  komakallio.example.com {
      reverse_proxy komakallio:PORT
  }
  ```
  For the canonical Caddy to reach this stack's `grafana` container, put both on a
  shared external Docker network (`docker network create edge-proxy`, joined from both
  compose files) rather than each app's fully isolated internal network. Mosquitto's
  TLS listener should read its certificate from whichever Caddy is canonical, the same
  way. Also cap TimescaleDB's memory settings explicitly (`shared_buffers`/`work_mem`
  overrides — a few hundred MB is plenty at this data volume) rather than trust image
  defaults sized for a box the stack no longer has entirely to itself, and watch actual
  usage with `docker stats` once both apps are running for a representative period.

**Checkpoint:** all containers report healthy; `https://metrics.example.com` shows the
Grafana login over a valid certificate. *(If sharing a host: the other app's hostname
still resolves and serves correctly, unaffected by this stack's deployment.)*

---

## 5. Phase 3 — Database schema (TimescaleDB)

Goal: a hypertable that ingests efficiently, rolls up automatically, and doesn't grow
without bound. Place this in `server/db/init/001_schema.sql` so it runs on first DB
startup.

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE sensor_readings (
    time         TIMESTAMPTZ      NOT NULL,
    site         TEXT             NOT NULL,   -- 'home', 'summer', …
    source       TEXT             NOT NULL DEFAULT 'ruuvi', -- identifies which pipeline/format produced this row
    sensor_id    TEXT             NOT NULL,   -- BLE MAC today; any stable per-device identifier in general
    sensor_name  TEXT,                        -- friendly name, filled by a lookup
    temperature  DOUBLE PRECISION,
    humidity     DOUBLE PRECISION,
    pressure     DOUBLE PRECISION,
    battery_mv   INTEGER,
    tx_power     INTEGER,
    rssi         INTEGER,
    accel_x      DOUBLE PRECISION,
    accel_y      DOUBLE PRECISION,
    accel_z      DOUBLE PRECISION,
    movement_ctr INTEGER,
    seq          INTEGER,
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

-- Drop raw rows older than 1 year (aggregates below keep the long history cheaply)
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
```

Notes:
- The schema is deliberately generic: `source` identifies which pipeline produced a row,
  `sensor_id` is any stable per-device identifier (not assumed to be a BLE MAC), the
  named columns cover common measurement types, and `extras` JSONB absorbs anything else
  — a value type, a unit, a count, whatever a future source needs — without a migration.
  This is where you recover most of the schema flexibility you liked about MongoDB, while
  keeping the common-case columns queryable directly for Grafana.
- If a future source's primary data doesn't fit the named columns well (e.g. it's
  fundamentally a single counter or event rather than a temperature/humidity/pressure
  reading), it can still use this same table — put the value(s) in `extras` and leave the
  unused named columns null. No new table is needed unless query patterns end up wanting
  one; the design defers that decision rather than assuming it now.
- Optionally add a small `sensor_names(sensor_id, name, site)` table and join it in
  dashboards, or let a source's decoder attach names (RuuviBridge supports a MAC→name
  map).

**Checkpoint:** `SELECT * FROM timescaledb_information.hypertables;` lists
`sensor_readings`; the continuous aggregate exists.

---

## 6. Phase 4 — Ingestion glue

Goal: raw packets in → clean rows in the hypertable, via a convention any future source
can plug into.

**Mosquitto** (`server/mosquitto/`):
- Enable a TLS listener on 8883.
- Create **one MQTT user per site** (`site-home`, `site-summer`, …) with a password.
- ACL file restricts each user to publish only under its own site prefix, e.g. `site-home`
  may write `home/#` and nothing else. A compromised edge node then can't touch other
  sites' data and can be revoked independently. Topics follow `<site>/<source>/<sensor_id>`
  for raw data — `source` distinguishes which pipeline/format a topic belongs to, so
  multiple kinds of publishers can coexist under the same site without collision.

**RuuviBridge** (`server/ruuvibridge/config.yml`) — the decoder for the current source:
- Source: MQTT listener subscribed to the raw `+/ruuvi/#` topics from the broker.
- Sink: the **MQTT publisher**, configured to publish each decoded measurement to its own
  topic under `decoded/<site>/ruuvi/<sensor_id>` (RuuviBridge supports "one measurement
  per topic," so the downstream consumer needs no JSON parsing).
- It decodes Ruuvi data formats 3, 5, 6, and E1 and can compute derived values.
- A future source with its own wire format would get its own decoder step following the
  same shape: subscribe to its raw topics, publish clean values under
  `decoded/<site>/<source>/<sensor_id>`. A source that already publishes clean values
  doesn't need a decoder at all — it just publishes directly into the `decoded/#`
  namespace itself.

**Telegraf** (`server/telegraf/telegraf.conf`) — source-agnostic:
- Input: `mqtt_consumer` subscribed to `decoded/#` (all sources, not just Ruuvi).
- Output: `postgresql`, pointed at the `timescaledb` service, inserting into
  `sensor_readings`.
- Map the topic structure to the `site` / `source` / `sensor_id` columns so every row is
  tagged with its origin, regardless of which source produced it. This mapping is the
  only place that needs to understand the topic shape — it doesn't need to understand any
  individual source's data format, since decoding already happened upstream.

**Alternative (one container instead of two):** skip RuuviBridge + Telegraf and run a
small custom consumer — `paho-mqtt` + a decoder for the relevant format + `psycopg` —
that subscribes to the raw topics, decodes, and inserts rows. Fewer moving parts, but
it's code you maintain instead of upstream images, and you'd write one such consumer per
source format that isn't already clean at the point of publishing. Either is fine; start
with the off-the-shelf pipeline for the current source.

**Checkpoint (using a temporary local publisher):**
`mosquitto_sub -t 'decoded/#'` shows clean values, and
`SELECT count(*) FROM sensor_readings;` climbs over time.

---

## 7. Phase 5 — First edge nodes (two profiles)

Goal: each real site working end to end. Edge hardware can differ per site, so the repo
defines **two edge profiles**; every site picks whichever matches its hardware.
Everything downstream (topics, schema, dashboards) is identical either way — this is the
only place deployment diverges.

### Profile A — native binary + systemd (ARMv6 boards only)

Use this only if a site's board is ARMv6 (e.g. an original Pi Zero W or Pi 1). Docker is
the fragile path there — many container images don't publish an `arm/v6` variant — so
this profile skips containers and runs the gateway as a plain binary under systemd.

1. **Flash the OS.** Raspberry Pi Imager → **Raspberry Pi OS Lite (32-bit)** — ARMv6
   cannot run the 64-bit OS. Pre-set hostname, SSH key, Wi-Fi, locale in the imager's
   settings so the board is headless-ready on first boot.
2. **First boot:** SSH in, `apt update && apt full-upgrade`. No Docker install.
3. **Get the binary.** Download the ARMv6 build of `ruuvi-go-gateway` from its releases
   page. If it fails to run (illegal instruction — Go's default `arm` target is now
   ARMv7), cross-compile one from any machine with Go installed:
   ```
   GOOS=linux GOARCH=arm GOARM=6 go build -o ruuvi-gateway ./cmd/ruuvi-go-gateway
   ```
4. **Clone the repo**, copy `edge/.env.example` → `edge/.env`, fill in the same variables
   as Profile B below, and template `edge/ruuvi-go-gateway/config.yml` from those values.
5. **Install as a systemd service** (`edge/systemd/ruuvi-gateway.service`):
   ```ini
   [Unit]
   Description=Ruuvi BLE gateway
   After=network-online.target bluetooth.target
   Wants=network-online.target

   [Service]
   ExecStart=/home/pi/sensor-platform/edge/ruuvi-gateway -config /home/pi/sensor-platform/edge/ruuvi-go-gateway/config.yml
   Restart=on-failure
   User=pi

   [Install]
   WantedBy=multi-user.target
   ```
   `systemctl enable --now ruuvi-gateway`.
6. Use a known-good power supply — undervoltage on small ARM boards shows up as flaky
   Wi-Fi/Bluetooth, especially bad at a remote site.

### Profile B — Docker (default; x86_64 and ARMv7/ARMv8 boards)

Use this for anything Docker-capable — the default choice for most hardware.

1. **Base OS.** Any standard Linux distro (Debian/Ubuntu Server, or Raspberry Pi OS Lite
   64-bit for a Pi 3-series or better), installed and configured for headless SSH access.
2. **Install Docker** (`curl -fsSL https://get.docker.com | sh`), add your user to the
   `docker` group.
3. **Clone the repo**, copy `edge/.env.example` → `edge/.env`:
   ```
   SITE=<site-name>
   MQTT_HOST=metrics.example.com
   MQTT_PORT=8883
   MQTT_USER=site-<site-name>
   MQTT_PASS=…
   ```
4. **`edge/ruuvi-go-gateway/config.yml`:** set the MQTT target (host/port/TLS/credentials
   from env), the topic prefix `${SITE}/ruuvi`, and whether to forward only Ruuvi data or
   all BLE.
5. **`edge/docker-compose.yml`** runs the gateway. Bluetooth in a container needs host
   networking and raw-socket capabilities:
   ```yaml
   services:
     ruuvi-gateway:
       image: ghcr.io/scrin/ruuvi-go-gateway
       network_mode: host
       cap_add: [NET_ADMIN, NET_RAW]
       volumes:
         - ./ruuvi-go-gateway/config.yml:/config.yml:ro
       restart: unless-stopped
   ```
   > BLE scanning from inside Docker requires host networking and access to the host's
   > Bluetooth stack (BlueZ). If scanning fails, confirm `bluetooth.service` is running
   > on the host and that no other process is holding the adapter. Running
   > `hcitool lescan` on the host first confirms the tags are visible at all.
6. `docker compose -f edge/docker-compose.yml up -d`.

**Checkpoint (both profiles):** on the VPS, `mosquitto_sub -t '<site>/ruuvi/#'` shows raw
packets for each site, decoded values appear on `decoded/#`, rows land in
`sensor_readings` tagged with the right `site` and `source`, and a quick Grafana panel
plots a temperature from each location.

---

## 8. Phase 6 — Grafana dashboards

Goal: useful views, defined as code so they're reproducible on any rebuild.

- **Datasource as code:** `grafana/provisioning/datasources/` defines the PostgreSQL
  datasource pointing at the `timescaledb` service (with TimescaleDB/PostgreSQL mode
  enabled). No clicking required on a fresh install.
- **Starter dashboard** with a `site` template variable and panels for temperature,
  humidity, pressure, and battery per sensor. For long ranges, query
  `sensor_readings_hourly` instead of the raw table so panels stay fast.
- Export finished dashboards to JSON and commit them under
  `grafana/provisioning/dashboards/`.
- **Alerts worth setting up** (Grafana's built-in alerting):
  - **Sensor offline** — no rows from a `sensor_id` in the last N minutes.
  - **Low battery** — `battery_mv` below a threshold (for sources that report it).
  - **Freeze warning at the summer place** — temperature approaching 0 °C in a space with
    water pipes. This alone can justify the whole project for an unheated cottage.

**Checkpoint:** dashboards render on a fresh Grafana container purely from provisioning;
at least one alert fires correctly in a test.

**Authentication & sessions (later, not needed for initial build).** Grafana requires
login by default (the admin account from Phase 2), which covers basic password
authentication out of the box — nothing extra to add for that part. Two things worth
doing once the stack is otherwise working, so you're not logging in constantly:
- **Extend session/cookie lifetime** via `GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION`
  and `GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION` (Grafana env vars, set alongside the
  other `GF_*` settings in Phase 2) so a session persists across browser restarts
  instead of expiring quickly.
- **Optionally, an external auth provider** (OAuth/OIDC — e.g. sign in with an existing
  Google/GitHub account) if you'd rather not manage a separate Grafana-only password at
  all. Not required; the built-in login is sufficient to start.
This applies to the Grafana web UI specifically — MQTT already has its own per-site
credential/ACL scheme (Phase 4), which is unrelated and doesn't need revisiting here.

---

## 9. Phase 7 — Scaling to many edge nodes (the fleet)

This is the payoff of the "dumb edge + config-as-code" design: a new site or source is
almost entirely repeated work.

**Tier 1 — one-command bootstrap (start here).**
`scripts/bootstrap-edge.sh` reduces a new node to: *flash/install OS → SSH in → run the
script.* It takes the deployment profile as a parameter and branches accordingly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# usage: bootstrap-edge.sh <SITE> <MQTT_USER> <MQTT_PASS> <PROFILE: docker|binary>
git clone https://…/sensor-platform.git ~/sensor-platform || \
  git -C ~/sensor-platform pull                         # 1. repo
cat > ~/sensor-platform/edge/.env <<EOF                 # 2. per-site config
SITE=$1
MQTT_HOST=metrics.example.com
MQTT_PORT=8883
MQTT_USER=$2
MQTT_PASS=$3
EOF

if [ "$4" = "docker" ]; then                             # Profile B
  curl -fsSL https://get.docker.com | sh
  docker compose -f ~/sensor-platform/edge/docker-compose.yml up -d
else                                                      # Profile A
  ARCH_TAG=$(uname -m)                                    # pick the matching binary
  cp ~/sensor-platform/edge/bin/ruuvi-gateway-"$ARCH_TAG" ~/sensor-platform/edge/ruuvi-gateway
  chmod +x ~/sensor-platform/edge/ruuvi-gateway
  sudo cp ~/sensor-platform/edge/systemd/ruuvi-gateway.service /etc/systemd/system/
  sudo systemctl enable --now ruuvi-gateway
fi
```

Per site you only: create a new MQTT user + ACL entry on the VPS, then run the script
with that site's name, credentials, and profile (`docker` for x86_64/capable ARM,
`binary` for ARMv6). Everything else is identical and comes from Git.

**Tier 2 — Ansible (once you have ~3+ nodes).**
Manage the whole fleet from your laptop or the VPS with one command.

- `ansible/inventory.ini` lists the nodes, grouped by profile so the playbook can branch:
  ```ini
  [edge_docker]
  ruuvi-home    ansible_host=192.168.1.20     # any Docker-capable host

  [edge_binary]
  ruuvi-summer  ansible_host=100.x.x.x        # ARMv6 board, e.g. over Tailscale
  ```
- `host_vars/<hostname>.yml` holds each node's `site`, MQTT credentials
  (**vault-encrypted**), and — for `edge_binary` hosts — its architecture tag so the
  playbook fetches the right prebuilt binary.
- `provision-edge.yml` has two roles: one installs Docker and starts the compose service
  (for `edge_docker` hosts), the other copies the matching binary and installs the
  systemd unit (for `edge_binary` hosts). Both roles template `.env`/config from the same
  host vars structure, so adding a site is just adding inventory + host vars — no new
  script logic.
- Deploy or update the entire fleet with `ansible-playbook -i inventory.ini
  provision-edge.yml`. Config changes become a Git commit + one playbook run.

**Tier 3 — golden image (optional shortcut).**
Once one Pi is perfect, image its SD card and clone it for new sites; on first boot just
change the hostname and `.env`. Fast, but Ansible stays cleaner for ongoing changes.

**Keeping edges current:** for `edge_docker` hosts, either run
[Watchtower](https://github.com/containrrr/watchtower) to auto-pull new images, or drive
`docker compose pull && up -d` from the Ansible playbook (more control, rolling updates).
For `edge_binary` hosts, updates just mean the playbook copying a newer binary and
restarting the systemd unit — no image registry involved.

**Reaching remote nodes:** a remote site's edge node likely won't have a public IP. Put
the fleet on a mesh VPN such as **Tailscale** so you can SSH/Ansible into every site as
if it were local, regardless of NAT. (The MQTT data path to the VPS is outbound and needs
no inbound access.)

---

## 10. Phase 8 — Weather data (optional, later)

Two clean options, both landing in the same `sensor_readings` table with
`source='weather'`:

- **FMI open data** (Finnish Meteorological Institute) — free open weather observations
  via their WFS stored-query API. A small scheduled fetcher (a cron'd container, a
  systemd timer, or Telegraf's HTTP input) pulls the nearest station's observations and
  inserts them. Pick the closest observation station to each site. Check FMI's current
  open-data access terms when you build this.
- **A physical weather station at the summer place** — feed it through the *same* MQTT
  path and topic convention as any other source (many stations can publish MQTT
  directly), so it's just another entry in the `decoded/#` namespace.

This phase is a useful worked example of the design paying off: adding a source here is
just "give it a `source` name and point it at the ingestion contract," not a schema or
pipeline change.

---

## 11. Operations & maintenance

- **Backups.** `pg_dump` of the database on a nightly cron inside a small container or
  host job, copied **off the VPS** (object storage or another machine). Periodically
  test a restore into a throwaway container — an untested backup isn't a backup. Also
  snapshot the Docker volumes if your provider supports it.
- **Disk watch.** Compression + retention keep growth bounded, but alert on VPS disk
  usage anyway.
- **Data lifecycle & resolution tiers (policy to confirm).** Raw beacons arrive at
  ~0.8 Hz/tag, so full-resolution storage grows quickly. Two independent levers:
  **compression is lossless** — it shrinks storage ~10–15× while keeping *every* beacon, so
  full resolution stays cheap for a long time; **downsampling** trades resolution for space
  (keep per-bucket min/avg/max, drop the raw). Target shape: raw **uncompressed for ~1–2
  days** (fast, full detail for spotting quick changes) → **compressed raw** for the medium
  term (still full resolution) → **downsampled** older data via a 1-minute continuous
  aggregate plus the existing hourly rollup, with raw dropped. Decide the crossover days and
  which continuous aggregates to add — compression (7 d) and raw retention (365 d) already
  exist, so this is mainly "compress sooner?" and "add a 1-min tier and drop raw after N
  days?". Quick win: drop redundant duplicate-gateway rows (e.g. a temporary second
  collector publishing the same tags under a different site).
- **Server updates.** `docker compose pull && docker compose up -d` on a cadence. Read
  TimescaleDB release notes before any **major** Postgres version jump (that's a
  migration, not a simple pull).
- **Time sync.** Small ARM boards typically have no real-time clock. Ensure NTP is active
  on each edge device (default on most Linux distros). Simplest correctness choice: rely
  on the server-side ingest timestamp, or have each source's decoder/gateway attach
  timestamps — just be consistent across sources.
- **Sensor cross-calibration.** Sensors of the same type rarely read identically. To
  correct, do a one-off calibration run: co-locate all the sensors in a stable, well-mixed
  spot (e.g. bundled together, insulated) for a period, then over that window compute each
  sensor's mean offset from the group mean and store it as a per-sensor correction term
  (e.g. temperature/humidity offset held with the sensor's metadata) applied at query
  time. Re-run whenever a sensor is added or replaced. Deferred until there's a run to
  derive it from.
- **Flaky summer-place internet.** MQTT tolerates high latency and reconnects on its own,
  so brief outages just cause gaps. But most gateways/publishers forward in real time and
  do **not** buffer across long outages — if gap-free history from a site matters, add a
  store-and-forward step at that edge (e.g. buffer to a local queue/DB and replay on
  reconnect). Otherwise, accept the gaps.
- **Revoking a site.** Delete its MQTT user + ACL entry on the VPS; the node is instantly
  cut off without affecting anything else.

---

## 12. Build order — milestone checklist

Each milestone below is committed to Git as soon as its checkpoint passes (principle 5)
— the list below is the order of *working states*, not just tasks to finish and batch up.

- [ ] **M0 — Verified data source:** repo created; local test script confirms readable
      RuuviTag data (Phase 0). The actual starting point.
- [ ] **M1 — Foundation:** VPS hardened; Docker installed; DNS pointed.
- [ ] **M2 — Server up:** full compose stack healthy; Grafana reachable over HTTPS.
- [ ] **M3 — Schema live:** hypertable + compression + retention + continuous aggregate.
- [ ] **M4 — Glue proven:** the test script (now publishing over MQTT) flows through
      decode → rows in DB.
- [ ] **M5 — First site:** first edge node set up and forwarding; end-to-end data in
      Grafana.
- [ ] **M6 — Dashboards & alerts:** provisioned as code; freeze/offline/battery alerts.
- [ ] **M7 — Repeatable edge:** bootstrap script turns a blank device into a live site in
      one run.
- [ ] **M8 — Fleet & extras:** second site added; (Ansible + Tailscale as sites grow);
      weather source; backups running and test-restored.

---

*Next step: generate the actual files — `server/docker-compose.yml`, all the configs
(Caddyfile, mosquitto.conf + ACL, ruuvibridge/config.yml, telegraf.conf), the schema SQL,
the edge compose + gateway config, `bootstrap-edge.sh`, and the Ansible playbook — so the
repo is ready to commit and deploy.*
