# Edge Profile C — BlueZ-cooperative BLE publisher

For edge nodes that must **share their Bluetooth adapter with a desktop** — e.g. a
machine running GNOME with a Bluetooth keyboard/mouse. Use this **instead of** the
Profile B gateway (`edge/docker-compose.yml`) on those nodes.

## Why this exists

`ruuvi-go-gateway` (Profile B) scans by seizing the **raw HCI socket**. On a node that
also runs `bluetoothd` for HID peripherals, the two fight over the one radio: an
adapter reset knocks the gateway deaf, and the gateway's HCI churn periodically drops
the keyboard/mouse — even powering the adapter off. See
[EDGE-SETUP.md → Gateway reliability](../../docs/EDGE-SETUP.md) and the watchdog.

This publisher instead scans **through BlueZ over D-Bus** (`bleak` → `bluetoothd`) —
the *same* cooperative path the desktop's own peripherals use. There is then exactly
**one owner of the radio** (bluetoothd), which time-slices scanning against the HID
connections. No raw-HCI contention exists by construction, so the mouse/keyboard are
never disturbed.

It's the same scanner the project used for M0/M4 verification
(`scripts/test-publisher/ruuvi_test_publisher.py`) — promoted to a real edge runtime.
It forwards **all** Ruuvi data formats (DF5 tags, DF6/E1 Ruuvi Air, …) as raw Ruuvi
Gateway JSON to `<site>/ruuvi/<mac>`; RuuviBridge decodes them server-side, exactly as
for Profile B. Downstream (topics, decoder, schema, dashboards) is unchanged.

## Trade-offs vs Profile B

- ✅ Coexists with desktop Bluetooth; no dongle, no second machine.
- ✅ No `NET_ADMIN`/`NET_RAW`, no host networking — just the D-Bus socket.
- ⚠️ Python you maintain vs. an upstream image (small; the script is in the repo).
- ⚠️ BlueZ de-duplicates advertisements, so per-beacon `seq` diagnostics are slightly
  lossier than raw-HCI capture. Irrelevant for temp/humidity/pressure/air cadence.

## Requirements on the host

- `bluetoothd` running, and the adapter **powered on at boot**: set `AutoEnable=true`
  under `[Policy]` in `/etc/bluetooth/main.conf` (headless Pi OS Lite doesn't by
  default; a desktop usually does).
- Docker + the docker group (as Profile B).
- `edge/.env` present (same file `bootstrap-edge.sh` writes): `SITE`, `MQTT_HOST`,
  `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`.

## Deploy

```bash
cd ~/sensor-platform
# make sure Profile B's gateway is NOT also running (they'd double-publish):
docker rm -f ruuvi-go-gateway 2>/dev/null || true
docker compose -f edge/ble-publisher/docker-compose.yml up -d --build
docker compose -f edge/ble-publisher/docker-compose.yml logs -f   # watch it find tags
```

## Reliability

The publisher exits non-zero (→ `restart: unless-stopped` recycles it) if **no BLE
advertisements arrive for `--stale-exit-seconds`** (default 180 in the compose). It
deliberately does **not** power the adapter on — on a desktop node the radio belongs
to the user first. If a reset ever powers the adapter down, BlueZ's `AutoEnable`
brings it back and the publisher reconnects on the next restart. No external watchdog
cron needed (that was a Profile B raw-HCI workaround).
