# Ruuvi gateway watchdog

`ruuvi-go-gateway` scans BLE via a **raw Bluetooth HCI socket**. If the adapter is
reset or power-cycled — suspend/resume, `systemctl restart bluetooth`, `rfkill`, or
BlueZ contention on a node that also runs a desktop — the gateway's HCI socket dies
(`socketRead: unixPoll events 0x0008`, POLLERR) and it does **not** re-open it. The
process stays up and MQTT stays connected, but it **publishes nothing** — a silent
outage that `restart: unless-stopped` can't catch (nothing crashes).

`ruuvi-gateway-watchdog.sh` spots that signature in the container logs and restarts the
gateway. The fix is just "restart the container," so it needs **no root** — only
membership in the `docker` group. A state file suppresses restart loops.

## Install (Profile B / Docker nodes)

**User cron (no root):**
```
crontab -e
# add (use an absolute path to your checkout):
*/5 * * * * /home/<user>/sensor-platform/edge/watchdog/ruuvi-gateway-watchdog.sh
```

**Or a root systemd timer:**
```ini
# /etc/systemd/system/ruuvi-gateway-watchdog.service
[Service]
Type=oneshot
ExecStart=/home/<user>/sensor-platform/edge/watchdog/ruuvi-gateway-watchdog.sh
User=<user>            # a docker-group user, so no root docker access needed
```
```ini
# /etc/systemd/system/ruuvi-gateway-watchdog.timer
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```
`sudo systemctl enable --now ruuvi-gateway-watchdog.timer`

## Notes
- After any **manual** Bluetooth reset on the node, just `docker restart
  ruuvi-go-gateway` — instant, vs. the watchdog's ≤5 min.
- Complements the central **"sensor offline" alert** (Grafana / M6): the watchdog
  self-heals at the edge; the alert notifies you.
- Prevention helps too, per node: keep it from suspending, and stop the BT adapter
  auto-power-cycling (e.g. disable `btusb` autosuspend). Most acute on nodes that also
  run a desktop + BlueZ (keyboard/mouse), where BlueZ and the raw-HCI scan share one
  radio. A dedicated USB BT dongle for the gateway sidesteps the contention entirely.
