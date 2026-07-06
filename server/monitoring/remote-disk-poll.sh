#!/usr/bin/env bash
# Agentless disk-usage monitoring: SSH to each remote host, read `df` + /proc/loadavg,
# and insert a partial sensor_readings row (source='host', disk_pct + cpu_load1) so the
# host shows on the Perf board's disk/load panels like any other node. Nothing is
# installed on the remote box. Runs on a systemd timer on the platform VPS.
#
# Targets: "<site> <sensor_id> <ssh-alias>". The alias maps to the real hostname in the
# VPS's git-ignored ~/.ssh/config, so no external hostname is committed here.
set -uo pipefail

TARGETS=(
  "external panel panel-monitor"
)

for t in "${TARGETS[@]}"; do
  # shellcheck disable=SC2086
  set -- $t; site=$1; node=$2; dest=$3
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$dest" \
        'df --output=pcent / | tail -1 | tr -dc 0-9; echo; cut -d" " -f1 /proc/loadavg' 2>/dev/null) \
    || { echo "remote-disk-poll: $dest unreachable" >&2; continue; }
  disk=$(printf '%s\n' "$out" | sed -n 1p)
  load=$(printf '%s\n' "$out" | sed -n 2p)
  [ -n "$disk" ] || { echo "remote-disk-poll: $dest no disk value" >&2; continue; }
  docker exec -i server-timescaledb-1 psql -U telegraf -d sensors -qtA -c \
    "INSERT INTO sensor_readings(time,site,source,sensor_id,disk_pct,cpu_load1) VALUES (now(),'$site','host','$node',$disk,${load:-NULL});" \
    && echo "remote-disk-poll: $site/$node disk=${disk}% load=${load}"
done
