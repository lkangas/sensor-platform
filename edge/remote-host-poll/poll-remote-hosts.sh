#!/usr/bin/env bash
# Agentless host metrics over SSH, published to MQTT as source='host'.
#
# For targets too weak or too locked-down to run the host-metrics agent (e.g. a
# nearly-saturated Pi Zero streaming audio, soon to run an overlayfs read-only
# root): this runs on a stronger node on the same LAN, SSHes to each target,
# reads a handful of /proc + /sys files in ONE short remote command, and
# publishes the same JSON the agent would — so the target shows up on the Perf
# board like any other node. Nothing is installed or written on the target.
#
# Deliberately light on the target:
#  - one multiplexed SSH connection (ControlMaster/ControlPersist): the expensive
#    key exchange happens once, then each poll is just a new channel on the open
#    connection (the target holds one idle sshd — a few MB RAM, ~0 CPU);
#  - cpu_pct comes from the /proc/stat delta BETWEEN polls (a true interval
#    average) — the target never runs a 1 s sampling sleep;
#  - all parsing happens on this side; the remote command is ~15 tiny reads.
#
# Targets: REMOTE_TARGETS="<node>[:<ssh-alias>] ..." (alias defaults to node).
# The alias maps to user/hostname/key in this user's ~/.ssh/config (git-ignored),
# so no real hostname is committed. Target prerequisites: see README.md.
set -uo pipefail
set -f   # no globbing — we word-split remote output with `set --`

if [ -z "${SITE:-}" ] || [ -z "${MQTT_HOST:-}" ] || [ -z "${REMOTE_TARGETS:-}" ]; then
  ENV_FILE="${REMOTE_POLL_ENV:-$(cd "$(dirname "$0")/../.." && pwd)/edge/.env}"
  [ -f "$ENV_FILE" ] || { echo "remote-host-poll: need SITE/MQTT_*/REMOTE_TARGETS in env, or edge/.env at $ENV_FILE" >&2; exit 1; }
  set -a; . "$ENV_FILE"; set +a
fi
[ -n "${REMOTE_TARGETS:-}" ] || { echo "remote-host-poll: REMOTE_TARGETS is empty (set it in edge/.env)" >&2; exit 1; }
INTERVAL="${REMOTE_POLL_INTERVAL:-120}"

CM_DIR="${XDG_RUNTIME_DIR:-/tmp}/remote-host-poll"; mkdir -p "$CM_DIR"; chmod 700 "$CM_DIR"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10
          -o ControlMaster=auto -o ControlPath="$CM_DIR/%r@%h-%p" -o ControlPersist=15m
          -o ServerAliveInterval=30 -o ServerAliveCountMax=3)

# One tagged line per metric; a file the target lacks just yields an empty tag,
# and the corresponding field is omitted (same omit-what's-absent contract as the
# agent). POSIX sh (target may run dash) and exec-light. `u` is the rpi_volt
# hwmon's live under-voltage flag (0/1) — the vcgencmd throttle bitmask's LSB —
# used because /dev/vcio* is often root-only; published as `throttled`.
RCMD='echo l $(cut -d" " -f1 /proc/loadavg)
echo s $(sed -n 1p /proc/stat)
echo m $(sed -n "s/^MemTotal: *\([0-9]*\).*/\1/p;s/^MemAvailable: *\([0-9]*\).*/\1/p" /proc/meminfo | tr "\n" " ")
echo t $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
echo f $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
echo w $(sed -n 3p /proc/net/wireless)
echo d $(df -P / 2>/dev/null | sed -n 2p)
echo u $(cat /sys/class/hwmon/hwmon*/in0_lcrit_alarm 2>/dev/null)'

pub(){ mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-8883}" -u "$MQTT_USER" -P "$MQTT_PASS" \
        --capath /etc/ssl/certs -t "$1" -m "$2" || echo "remote-host-poll: publish failed ($1)" >&2; }
num(){ case "${1:-}" in ''|*[!0-9.-]*) return 1;; *) return 0;; esac; }
int(){ case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

declare -A PREV_TOT PREV_IDLE

echo "remote-host-poll: polling [$REMOTE_TARGETS] every ${INTERVAL}s -> $SITE/host/*" >&2
while true; do
  sleep "$INTERVAL"
  for tgt in $REMOTE_TARGETS; do
    node=${tgt%%:*}; dest=${tgt#*:}; [ "$dest" = "$tgt" ] && dest=$node
    out=$(ssh "${SSH_OPTS[@]}" "$dest" "$RCMD" 2>/dev/null) \
      || { echo "remote-host-poll: $dest unreachable" >&2; continue; }

    load1=""; stat=""; memt=""; mema=""; tmilli=""; khz=""; rssi=""; dpct=""; uv=""
    while IFS= read -r line; do
      # shellcheck disable=SC2086
      set -- $line; tag=${1:-}; shift || true
      case "$tag" in
        l) load1=${1:-};;
        s) shift; stat="$*";;                    # drop the "cpu" word, keep the jiffies
        m) memt=${1:-}; mema=${2:-};;
        t) tmilli=${1:-};;
        f) khz=${1:-};;
        w) rssi=${4:-}; rssi=${rssi%.};;         # "<if>: <status> <link> <level> ..." — level dBm
        d) dpct=${5:-}; dpct=${dpct%\%};;        # df -P: fs blocks used avail use% mount
        u) uv=${1:-};;
      esac
    done <<< "$out"

    # CPU% averaged over the whole poll interval: delta of (total, idle+iowait)
    # jiffies vs the previous poll. First poll (or a counter reset after target
    # reboot) just skips the field once and reseeds.
    cpu_pct=""
    if [ -n "$stat" ]; then
      # shellcheck disable=SC2086
      set -- $stat
      if [ $# -ge 8 ]; then
        tot=$(( $1+$2+$3+$4+$5+$6+$7+$8 )); idl=$(( $4+$5 ))
        pt=${PREV_TOT[$node]:-}; pidl=${PREV_IDLE[$node]:-}
        if [ -n "$pt" ] && [ $((tot-pt)) -gt 0 ] && [ $((idl-pidl)) -ge 0 ] && [ $((tot-pt)) -ge $((idl-pidl)) ]; then
          cpu_pct=$(awk -v d=$((tot-pt)) -v di=$((idl-pidl)) 'BEGIN{printf "%.1f",100*(d-di)/d}')
        fi
        PREV_TOT[$node]=$tot; PREV_IDLE[$node]=$idl
      fi
    fi

    temp="";    int "$tmilli" && temp=$(awk -v m="$tmilli" 'BEGIN{printf "%.1f",m/1000}')
    mhz="";     int "$khz" && mhz=$(( khz/1000 ))
    mem_pct=""; int "$memt" && int "$mema" && [ "$memt" -gt 0 ] \
                && mem_pct=$(awk -v t="$memt" -v a="$mema" 'BEGIN{printf "%.1f",(t-a)/t*100}')
    uv=${uv%% *}                                 # several hwmons? take the first

    j="{"; sep=""
    for kv in "cpu_pct:$cpu_pct" "temperature:$temp" "cpu_load1:$load1" "cpu_mhz:$mhz" \
              "mem_pct:$mem_pct" "disk_pct:$dpct" "wifi_rssi:$rssi" "throttled:$uv"; do
      v=${kv#*:}; num "$v" || continue
      j="$j$sep\"${kv%%:*}\": $v"; sep=", "
    done
    [ "$j" = "{" ] && { echo "remote-host-poll: $dest returned no usable metrics" >&2; continue; }
    pub "$SITE/host/$node" "$j}"
  done
done
