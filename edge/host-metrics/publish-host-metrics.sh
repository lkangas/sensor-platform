#!/usr/bin/env bash
# Publish this node's SoC temperature and Raspberry Pi throttle/undervoltage state to MQTT
# as a clean 'host' source:  <site>/host/<hostname>  {"temperature":.., "throttled":..}
#
# No decoder needed (already clean values) — Telegraf subscribes to +/host/+ and writes
# straight to sensor_readings (source='host'). Reuses the edge MQTT credentials from
# edge/.env and the broker's public (Let's Encrypt) TLS via the system CA store. Runs as a
# small loop under systemd (ruuvi-host-metrics.service).
#
# On a Pi, CPU and GPU share one SoC die → one temperature (thermal_zone0). throttled is
# the vcgencmd get_throttled bitmask: 0 = healthy; bit 0 under-voltage now, bit 2 throttled
# now, bit 16/18 the same latched since boot — the key signal for a remote, cold node.
set -uo pipefail

ENV_FILE="${HOST_METRICS_ENV:-$(cd "$(dirname "$0")/../.." && pwd)/edge/.env}"
[ -f "$ENV_FILE" ] || { echo "host-metrics: no edge/.env at $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
INTERVAL="${HOST_METRICS_INTERVAL:-30}"
TOPIC="${SITE}/host/$(hostname)"

soc_temp() { awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null; }
throttled() {
  command -v vcgencmd >/dev/null 2>&1 || { echo 0; return; }
  local h; h=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/.*=0x\([0-9A-Fa-f]\+\).*/\1/p')
  [ -n "$h" ] && printf '%d' "$((16#$h))" || echo 0
}

echo "host-metrics: publishing to ${TOPIC} every ${INTERVAL}s" >&2
while true; do
  t=$(soc_temp); th=$(throttled)
  if [ -n "$t" ]; then
    mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-8883}" -u "$MQTT_USER" -P "$MQTT_PASS" \
      --capath /etc/ssl/certs -t "$TOPIC" -m "{\"temperature\": ${t}, \"throttled\": ${th}}" \
      || echo "host-metrics: publish failed" >&2
  fi
  sleep "$INTERVAL"
done
