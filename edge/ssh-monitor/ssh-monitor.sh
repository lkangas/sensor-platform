#!/usr/bin/env bash
# Publish SSH exposure telemetry to MQTT as a 'security' source:
#   <site>/security/<node>  {ssh_failed, ssh_accepted, ssh_ips  (per interval, from journald),
#                            f2b_banned, f2b_banned_total        (from fail2ban-client)}
#
# TWO data sources on purpose: journald sees every auth attempt (attacks AND your own
# logins); fail2ban-client reports what it has actually blocked. Needs root — the full
# journal and the fail2ban socket are root-only. Reuses the MQTT creds from edge/.env
# (loaded by the systemd unit's EnvironmentFile, or point SSH_MONITOR_ENV at a file to
# source). Broker TLS via the system CA store (broker uses a public Let's Encrypt cert).
set -uo pipefail

if [ -z "${MQTT_HOST:-}" ] && [ -n "${SSH_MONITOR_ENV:-}" ]; then
  set -a; . "$SSH_MONITOR_ENV"; set +a
fi
[ -n "${MQTT_HOST:-}" ] || { echo "ssh-monitor: need MQTT_* env (EnvironmentFile or SSH_MONITOR_ENV)" >&2; exit 1; }

INTERVAL="${SSH_MONITOR_INTERVAL:-60}"
NODE="${HOST_NODE:-$(hostname)}"
TOPIC="${SITE:-home}/security/${NODE}"
SSH_UNIT="${SSH_UNIT:-ssh}"          # Debian/Ubuntu ssh daemon unit is 'ssh' (not 'sshd')

pub(){ mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-8883}" -u "$MQTT_USER" -P "$MQTT_PASS" \
        --capath /etc/ssl/certs -t "$1" -m "$2" || echo "ssh-monitor: publish failed" >&2; }

echo "ssh-monitor: publishing to $TOPIC every ${INTERVAL}s" >&2
while true; do
  sleep "$INTERVAL"
  # journald window = the interval just elapsed (small boundary imprecision is fine for a gauge)
  since=$(date -d "-${INTERVAL} seconds" '+%Y-%m-%d %H:%M:%S')
  log=$(journalctl -u "$SSH_UNIT" --since "$since" --no-pager 2>/dev/null || true)
  failed=$(grep -c "Failed password" <<<"$log" || true)
  accepted=$(grep -c "Accepted " <<<"$log" || true)
  ips=$(grep "Failed password" <<<"$log" | grep -oE 'from [0-9.]+' | awk '{print $2}' \
          | sort -u | grep -c . || true)
  # fail2ban's own counters
  f2b=$(fail2ban-client status sshd 2>/dev/null || true)
  banned=$(grep -oE 'Currently banned:[[:space:]]+[0-9]+' <<<"$f2b" | grep -oE '[0-9]+$'); banned=${banned:-0}
  btotal=$(grep -oE 'Total banned:[[:space:]]+[0-9]+' <<<"$f2b" | grep -oE '[0-9]+$'); btotal=${btotal:-0}

  pub "$TOPIC" "{\"ssh_failed\": ${failed:-0}, \"ssh_accepted\": ${accepted:-0}, \
\"ssh_ips\": ${ips:-0}, \"f2b_banned\": ${banned}, \"f2b_banned_total\": ${btotal}}"
done
