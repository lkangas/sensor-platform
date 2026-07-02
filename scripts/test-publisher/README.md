# test-publisher — Phase 0 local verification

A **throwaway** tool, not a real edge node. It answers "can I read my RuuviTags?"
before any VPS or edge hardware exists, and later smoke-tests the ingestion pipeline.

## Install

```
pip install -r requirements.txt
```

Cross-platform via [`bleak`](https://github.com/hbldh/bleak) — works natively on
Windows (no WSL needed), macOS, and Linux/BlueZ. `paho-mqtt` is only used for the
optional publishing mode.

## M0 — read-only (do this first)

```
python ruuvi_test_publisher.py          # scan until Ctrl-C
python ruuvi_test_publisher.py --once    # scan ~8s, print, exit
```

Expected output — a line per advertisement:

```
E2:1A:9C:33:7B:04  T=21.42°C  RH=38.75%  P=1013.2 hPa  batt=2971mV  seq=41210  rssi=-58
```

**Checkpoint (M0):** you see readable temperature / humidity / pressure from your
actual tags. This is the real starting point for the whole plan.

### Troubleshooting

- **No tags heard** — confirm Bluetooth is on and the tags are advertising in
  **Data Format 5** (the current default; this script decodes DF5). On Linux, make
  sure `bluetooth.service` is running.
- **Windows** — grant the terminal Bluetooth permission if prompted. Run from a normal
  (non-WSL) Python; WSL can't reach the Bluetooth adapter directly.
- **Older tags on DF3** — not decoded here; update the tag firmware or extend
  `decode_df5` with a DF3 branch.

## M4 — publish over MQTT (verified 2026-07-02)

With the VPS stack up, the same script pushes advertisements through the real
pipeline. It forwards **exactly like a real Ruuvi gateway**: topic
`<site>/ruuvi/<mac>`, payload in Ruuvi Gateway JSON format (raw advertisement hex
in `data`) — RuuviBridge does the decoding server-side.

```
# password: --mqtt-pass, $MQTT_PASS, or a git-ignored .env here (MQTT_PASS=...)
python ruuvi_test_publisher.py --once --once-seconds 75 \
    --mqtt-host petzval.dy.fi --mqtt-port 8883 --tls \
    --mqtt-user site-test --site test
```

Verified end-to-end: raw on `test/ruuvi/#` → RuuviBridge → clean JSON on
`decoded/test/ruuvi/#` → Telegraf → rows in `sensor_readings` with correct
site/source/sensor_id, pressure in hPa, battery in mV. RuuviBridge output
confirmed camelCase fields, pressure in Pa, batteryVoltage in volts — the
telegraf.conf conversions match.

Record each tag's MAC → friendly name as you identify them; that mapping is used later
in RuuviBridge / the `sensor_names` table.

## Running indefinitely (Windows)

`publisher-ctl.ps1` runs the publisher detached with a supervisor that restarts
it if it crashes. In `--quiet` mode the log only gets tag discoveries and a
15-minute heartbeat, so it stays small.

From **PowerShell** (in this directory):

```powershell
.\publisher-ctl.ps1 start     # launch, runs until stopped (survives closing the terminal)
.\publisher-ctl.ps1 status    # supervisor/publisher PIDs + last log lines
.\publisher-ctl.ps1 log       # tail the log
.\publisher-ctl.ps1 stop      # stop BOTH supervisor and publisher
```

From **WSL**:

```bash
powershell.exe -ExecutionPolicy Bypass -File \
  "C:\Users\lauri\OneDrive\code\monitoring\scripts\test-publisher\publisher-ctl.ps1" start   # or stop/status/log
```

Notes:
- **Stop uses the script, not taskkill** — killing only `python.exe` makes the
  supervisor restart it 10 s later; the script stops the supervisor first.
- It does **not** survive a reboot or sleep — this is still the throwaway test
  publisher, not a real edge node (that's M5). If the machine slept, just
  `start` again.
- Log: `%TEMP%\ruuvi-publisher.log` (fresh on each `start`).
