# Host / node metrics (`source='host'`)

Publishes the edge node's own health into the same pipeline as the sensors, tagged
`source='host'`. It's a *clean* source (no wire format to decode), so it publishes straight
to `<site>/host/<hostname>` and Telegraf reads `+/host/+` directly.

Each interval it emits one JSON object with whatever the box exposes — a field is omitted
when its source isn't present, so a row carries only what applies:

- **Everywhere:** `cpu_pct`, `temperature` (SoC/CPU °C), `cpu_load1`, `cpu_mhz`, `mem_pct`,
  `disk_pct`.
- **Raspberry Pi:** `throttled` (the `vcgencmd get_throttled` under-voltage/thermal bitmask
  — `0` is healthy, non-zero flags the signal that matters most for a cold, remote,
  marginally-powered node) and `core_volt`.
- **x86:** `ssd_temp` (NVMe), `power_w` (Intel RAPL), and per-core CPU temperatures on a
  second topic family `<site>/host/<hostname>-cpuN` (one `sensor_id` per core).
- **Wireless nodes:** `wifi_rssi`.

On a Pi, CPU and GPU are one SoC die, so there is one temperature.

## What lands in the DB
`sensor_readings` rows with `source='host'`, `sensor_id=<hostname>` (plus `<hostname>-cpuN`
for x86 per-core temps), carrying the fields above. Telegraf's `fieldinclude` whitelists
them; the columns come from `db/migrations/002_host_throttled.sql` (`throttled`) and
`003_host_metrics.sql` (the rest).

## Install (on the edge node)
Requires `mosquitto-clients`; reuses `edge/.env` (SITE + MQTT creds) and the broker's
public TLS cert.

```bash
sudo apt-get install -y mosquitto-clients
chmod +x ~/sensor-platform/edge/host-metrics/publish-host-metrics.sh
mkdir -p ~/.config/systemd/user
cp ~/sensor-platform/edge/host-metrics/ruuvi-host-metrics.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ruuvi-host-metrics
sudo loginctl enable-linger "$USER"   # keep the user service running across reboots/without login
```

Check: `systemctl --user status ruuvi-host-metrics` and, on the VPS,
`mosquitto_sub -t '+/host/#' -v`.

Config knobs (env): `HOST_METRICS_INTERVAL` (default 30 s), `HOST_METRICS_ENV` (path to
`.env`), `HOST_NODE` (the node's `sensor_id`; defaults to `hostname`). Non-Pi hosts simply
omit the Pi-only fields (`throttled`/`core_volt`) and add the x86 ones
(`ssd_temp`/`power_w`/per-core temps) where the kernel exposes them.

**Container-deploy caveat:** in a container `hostname` is the random container id, so set
`HOST_NODE` to the host's real name — **persistently**, in `edge/host-metrics/.env`
(`HOST_NODE=<hostname>`). Without it, every container recreate mints a fresh
`<container-id>-cpuN` series on the Perf board (systemd deploys are unaffected — they run on
the host and see the real hostname).
