# Host / node metrics (`source='host'`)

Publishes the edge node's own health — **SoC temperature** and the Raspberry Pi
**throttle/undervoltage** bitmask (`vcgencmd get_throttled`) — into the same pipeline as
the sensors, tagged `source='host'`. It's a *clean* source (no wire format to decode), so
it publishes straight to `<site>/host/<hostname>` and Telegraf reads `+/host/+` directly.

On a Pi, CPU and GPU are one SoC die, so there is **one** temperature. `throttled=0` is
healthy; non-zero flags under-voltage / thermal throttling — the signal that matters most
for a cold, remote, marginally-powered node.

## What lands in the DB
`sensor_readings` rows with `source='host'`, `sensor_id=<hostname>`, `temperature` = SoC
°C, `throttled` = bitmask. (Needs the `throttled` column — `db/migrations/002_host_throttled.sql`.)

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
`.env`). Non-Pi hosts without `vcgencmd` still publish temperature (throttled = 0); an
x86 box could instead feed `lm-sensors` here.
