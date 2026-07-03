#!/usr/bin/env bash
# Restart the Ruuvi gateway container if its BLE scan has silently wedged.
#
# WHY: ruuvi-go-gateway scans via a raw Bluetooth HCI socket. When the adapter is
# reset or power-cycled -- suspend/resume, `systemctl restart bluetooth`, rfkill, or
# BlueZ contention on a node that also runs a desktop -- the gateway's HCI socket dies
# ("socketRead: unixPoll events 0x0008", POLLERR) and it does NOT re-open it: the
# process stays up and MQTT stays connected, but it publishes nothing. Nothing
# crashes, so `restart: unless-stopped` can't catch it. This detects that signature
# and restarts the container.
#
# No root needed -- just membership in the `docker` group. Install via user cron or a
# root systemd timer; see edge/watchdog/README.md.
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

CID="${RUUVI_CID:-ruuvi-go-gateway}"          # container_name in edge/docker-compose.yml
WINDOW="${RUUVI_WINDOW:-30m}"                  # how far back to scan the logs
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ruuvi-watchdog/last-restart"
mkdir -p "$(dirname "$STATE")"
last=$(cat "$STATE" 2>/dev/null || echo 0)

# newest HCI-wedge line (POLLERR on the raw HCI socket), with its RFC3339 timestamp
line=$(docker logs --timestamps --since="$WINDOW" "$CID" 2>&1 \
        | grep -E "unixPoll events 0x0008" | tail -1 || true)
[ -n "$line" ] || exit 0

ts=$(printf '%s' "$line" | awk '{print $1}')
err_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)

# restart only if the wedge is newer than our last restart -> no restart loops
if [ "$err_epoch" -gt "$last" ]; then
  logger -t ruuvi-watchdog "BLE scan wedged (HCI POLLERR at $ts) -> restarting $CID"
  docker restart "$CID" >/dev/null
  date +%s > "$STATE"
fi
