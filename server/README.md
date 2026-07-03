# server/ — VPS stack (M2/M3)

Six services on one compose network: Caddy (HTTPS) → Grafana → TimescaleDB ←
Telegraf ← Mosquitto ← RuuviBridge (one per site). Only Caddy (80/443) and
Mosquitto's TLS listener (8883) are exposed; everything else is internal.

## Deploy (fresh VPS, M1 done)

```bash
# on the VPS
git clone https://github.com/lkangas/sensor-platform.git ~/sensor-platform
cd ~/sensor-platform/server

# 1. secrets — generate strong values into .env (git-ignored)
cp .env.example .env
for k in POSTGRES_PASSWORD TELEGRAF_DB_PASS GRAFANA_DB_PASS GF_SECURITY_ADMIN_PASSWORD; do
  sed -i "s|^$k=.*|$k=$(openssl rand -base64 24 | tr -d '/+=')|" .env
done

# 2. per-site MQTT users (external 8883 listener) — file is git-ignored
docker run --rm -v "$PWD/mosquitto:/work" eclipse-mosquitto:2 \
  mosquitto_passwd -c -b /work/passwd site-test '<password-for-site-test>'
# additional sites: same command without -c
# the container writes it root-owned; mosquitto reads it as uid 1883:
sudo chown 1883:1883 mosquitto/passwd && sudo chmod 600 mosquitto/passwd

# 3. up
docker compose up -d
docker compose ps
```

## Checkpoints

- **M2:** all containers healthy; `https://vps.example.com` shows the Grafana login
  over a valid certificate.
- **M3:** `docker compose exec timescaledb psql -U postgres -d sensors -c
  "SELECT * FROM timescaledb_information.hypertables;"` lists `sensor_readings`.
- **M4:** `mosquitto_sub` on `decoded/#` shows clean values while the Phase 0
  publisher runs; `SELECT count(*) FROM sensor_readings;` climbs.

## Notes / decisions

- **TLS for MQTT** reuses Caddy's Let's Encrypt cert via a shared volume;
  `mosquitto/entrypoint.sh` copies it with mosquitto-readable ownership and HUPs
  the broker when the cert renews. Mosquitto therefore waits for Caddy's first
  ACME issuance on a cold start.
- **Internal 1883 is anonymous** (never published to the host): the trust
  boundary is compose-network membership. This keeps broker credentials out of
  the ruuvibridge/telegraf configs, so those are committable as-is. External
  8883 uses per-site users + write-only-own-prefix ACL.
- **One RuuviBridge per site** — its publisher topic prefix is static, so
  per-site instances are how `decoded/<site>/…` keeps the site segment. Adding a
  site: new config-<site>.yml + compose service + ACL entry + passwd user.
- **Telegraf whitelists fields** (`fieldinclude`) so an unexpected field can
  never ALTER the table; unknown data belongs in `extras` (future sources).
- **Ruuvi Air (data format E1)** rides the existing `ruuvi` pipeline unchanged —
  same gateway, same `<site>/ruuvi/<mac>` topics, same per-site RuuviBridge (it
  decodes E1). Air rows differ only by which columns are populated (`co2`, `pm2_5`,
  `voc`, …), not by `source`. The `sensor_readings` columns + Telegraf whitelist are
  staged; on the **live** DB apply the columns once:
  `docker compose exec -T timescaledb psql -U postgres -d sensors < db/migrations/001_air_quality.sql`,
  then `docker compose restart telegraf`. Fresh rebuilds get the columns from
  `db/init/001_schema.sql` automatically.
- **Provisional until M4:** RuuviBridge's exact JSON field names/units
  (camelCase, pressure Pa, battery V assumed) — the starlark/rename blocks in
  telegraf.conf encode the assumptions and get verified against live data.
- Images are unpinned until first deploy; pin to digests once verified.
