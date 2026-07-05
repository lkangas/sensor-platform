# FMI weather poller

Pulls open weather observations from the **Finnish Meteorological Institute** and feeds
them into the same pipeline as the sensors, so they appear on the dashboards as an
external reference line.

- `fmi_weather.py` — polls each configured station every ~10 min (FMI's observation
  cadence) and publishes `{"temperature": …}` to `decoded/<site>/fmi/<label>`. Telegraf
  maps that to `sensor_readings` with `source='fmi'`, `sensor_id=<label>`. From there it
  rides the 1-minute aggregate, adaptive views, compression and retention for free.
- `backfill.py` — one-off: prints SQL to load N days of history (see below).

No API key is required (`opendata.fmi.fi`). Data © FMI, licensed **CC BY 4.0** — keep the
attribution where the data is shown.

## Config (private)

Which weather station backs which site reveals location, so the real config is
**git-ignored** — only `stations.example.json` is committed (same model as `tags.csv`).

```bash
cp stations.example.json stations.json    # git-ignored; edit with real stations
```

Each entry: `site` (matches the edge site, e.g. `home` / `summer`), `label` (the display
name shown on the dashboards, e.g. `FMI <place>`), `fmisid` (the numeric FMI station id —
find it at https://en.ilmatieteenlaitos.fi/observation-stations or by querying the WFS
`place=` API), and `parameters` (FMI names; start with `["temperature"]`, add
`humidity`/`pressure` later with no schema change).

The dashboards match these rows generically (`sensor_id LIKE 'FMI%'`, labelled from the
data), so no station name or id lives in the committed repo.

## Run

Provisioned as the `fmi-weather` compose service (mounts `stations.json`, needs the
`mosquitto` broker). `docker compose up -d --build fmi-weather`.

## Backfill history (one-off)

```bash
STATIONS_FILE=./stations.json python3 backfill.py 7 \
  | docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1
# then refresh the aggregate over the backfilled range so long-window views pick it up:
#   CALL refresh_continuous_aggregate('sensor_readings_1min', now()-interval '8 days', now());
```
