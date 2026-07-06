#!/usr/bin/env bash
# Agentless disk-usage monitoring: SSH to each remote host, read `df` + /proc/loadavg,
# and insert a partial sensor_readings row (source='host', disk_pct + cpu_load1 + mem_pct + cpu_pct) so the
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
  # Remote outputs 4 lines: disk% / load1 / mem% / cpu%. cpu% needs a ~1s /proc/stat
  # delta (total = user..steal, idle = idle+iowait), matching edge/host-metrics.
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=12 "$dest" \
        'df --output=pcent / | tail -1 | tr -dc 0-9; echo; cut -d" " -f1 /proc/loadavg; awk "/^MemTotal/{t=\$2}/^MemAvailable/{a=\$2}END{if(t)printf \"%.1f\",(t-a)/t*100}" /proc/meminfo; echo; read _ u1 n1 s1 id1 io1 ir1 sf1 st1 _ < /proc/stat; T1=$((u1+n1+s1+id1+io1+ir1+sf1+st1)); I1=$((id1+io1)); sleep 1; read _ u2 n2 s2 id2 io2 ir2 sf2 st2 _ < /proc/stat; T2=$((u2+n2+s2+id2+io2+ir2+sf2+st2)); I2=$((id2+io2)); D=$((T2-T1)); [ "$D" -gt 0 ] && echo $(( (D-(I2-I1))*100/D ))' 2>/dev/null) \
    || { echo "remote-disk-poll: $dest unreachable" >&2; continue; }
  disk=$(printf '%s\n' "$out" | sed -n 1p)
  load=$(printf '%s\n' "$out" | sed -n 2p)
  mem=$(printf  '%s\n' "$out" | sed -n 3p)
  cpu=$(printf  '%s\n' "$out" | sed -n 4p)
  [ -n "$disk" ] || { echo "remote-disk-poll: $dest no disk value" >&2; continue; }
  docker exec -i server-timescaledb-1 psql -U telegraf -d sensors -qtA -c \
    "INSERT INTO sensor_readings(time,site,source,sensor_id,disk_pct,cpu_load1,mem_pct,cpu_pct) VALUES (now(),'$site','host','$node',$disk,${load:-NULL},${mem:-NULL},${cpu:-NULL});" \
    && echo "remote-disk-poll: $site/$node disk=${disk}% load=${load} mem=${mem}% cpu=${cpu}%"
done
