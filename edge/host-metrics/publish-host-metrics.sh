#!/usr/bin/env bash
# Publish this node's health metrics to MQTT as a clean 'host' source:
#   <site>/host/<node>        {cpu_pct, temperature, cpu_load1, cpu_mhz, mem_pct, disk_pct,
#                              + throttled/core_volt (Pi), power_w/ssd_temp (x86), wifi_rssi}
#   <site>/host/<node>-cpuN   {"temperature": <core N °C>}     (x86 per-core, if present)
#
# Capability-detecting: works on a Raspberry Pi (vcgencmd) and x86 (coretemp/RAPL/nvme).
# No decoder needed — Telegraf reads +/host/+. Reuses edge/.env creds + the broker's public
# (Let's Encrypt) TLS via the system CA store. Runs as a small loop (systemd or a container).
set -uo pipefail

if [ -z "${SITE:-}" ] || [ -z "${MQTT_HOST:-}" ]; then   # container passes these via env_file
  ENV_FILE="${HOST_METRICS_ENV:-$(cd "$(dirname "$0")/../.." && pwd)/edge/.env}"
  [ -f "$ENV_FILE" ] || { echo "host-metrics: need SITE/MQTT_* in env, or edge/.env at $ENV_FILE" >&2; exit 1; }
  set -a; . "$ENV_FILE"; set +a
fi
INTERVAL="${HOST_METRICS_INTERVAL:-30}"
BASE="${SITE}/host/$(hostname)"

pub(){ mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-8883}" -u "$MQTT_USER" -P "$MQTT_PASS" \
        --capath /etc/ssl/certs -t "$1" -m "$2" || echo "host-metrics: publish failed ($1)" >&2; }

hwmon_temp(){ # $1=hwmon name  [$2=label] -> °C
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] || continue
    for f in "$h"/temp*_input; do
      [ -e "$f" ] || continue
      [ -z "${2:-}" ] || [ "$(cat "${f%_input}_label" 2>/dev/null)" = "$2" ] || continue
      awk '{printf "%.1f", $1/1000; exit}' "$f"; return
    done
  done
}
cpu_temp(){ local t; t=$(hwmon_temp coretemp "Package id 0"); [ -n "$t" ] && { echo "$t"; return; }
  t=$(hwmon_temp cpu_thermal); [ -n "$t" ] && { echo "$t"; return; }
  [ -e /sys/class/thermal/thermal_zone0/temp ] && awk '{printf "%.1f",$1/1000}' /sys/class/thermal/thermal_zone0/temp; }
mem_pct(){ awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{if(t)printf "%.1f",(t-a)/t*100}' /proc/meminfo; }
disk_pct(){ df -P / | awk 'NR==2{gsub("%","",$5);print $5}'; }
cpu_mhz(){ for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do cat "$c" 2>/dev/null; done \
             | awk '{s+=$1;n++}END{if(n)printf "%d",s/1000/n}'; }
load1(){ cut -d' ' -f1 /proc/loadavg; }
throttled(){ command -v vcgencmd >/dev/null || return; local r; r=$(vcgencmd get_throttled 2>/dev/null)
  case "$r" in *=0x*) printf '%d' "$((16#${r#*=0x}))";; esac; }
core_volt(){ command -v vcgencmd >/dev/null || return
  vcgencmd measure_volts core 2>/dev/null | sed -n 's/.*=\([0-9.]*\)V.*/\1/p'; }
ssd_temp(){ hwmon_temp nvme "Composite"; }
wifi_rssi(){ command -v iw >/dev/null || return
  for w in /sys/class/net/*/wireless; do [ -e "$w" ] || continue
    iw dev "$(basename "$(dirname "$w")")" link 2>/dev/null | sed -n 's/.*signal: \(-\?[0-9]*\) dBm.*/\1/p'; return; done; }
rapl_uj(){ cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null; }
stat_tot(){ awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6; exit}' /proc/stat; }

read PT PI < <(stat_tot); PE=$(rapl_uj); PTS=$(date +%s)
echo "host-metrics: publishing to $BASE every ${INTERVAL}s" >&2
while true; do
  sleep "$INTERVAL"
  read T I < <(stat_tot)
  cpu_pct=$(awk -v d=$((T-PT)) -v di=$((I-PI)) 'BEGIN{printf "%.1f",d?100*(d-di)/d:0}'); PT=$T; PI=$I
  power=""; E=$(rapl_uj); NOW=$(date +%s)
  if [ -n "$E" ] && [ -n "$PE" ] && [ "$((E-PE))" -ge 0 ] && [ "$NOW" -gt "$PTS" ]; then
    power=$(awk -v de=$((E-PE)) -v dt=$((NOW-PTS)) 'BEGIN{printf "%.1f",(de/1e6)/dt}'); fi
  PE=$E; PTS=$NOW
  j="{\"cpu_pct\": ${cpu_pct}"
  for kv in "temperature:$(cpu_temp)" "cpu_load1:$(load1)" "cpu_mhz:$(cpu_mhz)" \
            "mem_pct:$(mem_pct)" "disk_pct:$(disk_pct)" "throttled:$(throttled)" \
            "core_volt:$(core_volt)" "ssd_temp:$(ssd_temp)" "wifi_rssi:$(wifi_rssi)"; do
    v=${kv#*:}; [ -n "$v" ] && j="$j, \"${kv%%:*}\": $v"; done
  [ -n "$power" ] && j="$j, \"power_w\": $power"
  pub "$BASE" "$j}"
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = coretemp ] || continue
    for f in "$h"/temp*_input; do
      case "$(cat "${f%_input}_label" 2>/dev/null)" in
        Core\ *) n=$(cat "${f%_input}_label"); n=${n#Core }
                 pub "${BASE}-cpu${n}" "{\"temperature\": $(awk '{printf "%.1f",$1/1000}' "$f")}";; esac
    done; done
done
