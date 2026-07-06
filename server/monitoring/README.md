# Remote disk poller (agentless)

Disk-usage monitoring for hosts we don't want to install anything on (e.g. a VPS
running someone else's app). A systemd timer on the platform VPS SSHes to each target,
reads `df` + `/proc/loadavg` + `/proc/meminfo` + a ~1s `/proc/stat` delta, and inserts a
partial `sensor_readings` row (`source='host'`, `disk_pct` + `cpu_load1` + `mem_pct` +
`cpu_pct`) — so the host shows on the Perf board's disk/load/memory/cpu panels like any other
node. **Nothing runs on the remote box.**

Contrast with `edge/host-metrics/`, which is the *agent* version (a publisher running on
the host over MQTT, full metrics). Use the poller when the remote box must stay clean; use
the agent when you want richer metrics and prefer outbound-only telemetry over granting the
VPS inbound SSH.

## Targets
Edit the `TARGETS` array in `remote-disk-poll.sh`: `"<site> <sensor_id> <ssh-alias>"`. The
alias maps to the real hostname in the VPS's **git-ignored** `~/.ssh/config`, so no external
hostname is committed here. Each target needs:
- an SSH key on the VPS authorized on the target (outbound, key-only), and
- the target's host key in the VPS's `~/.ssh/known_hosts`.

## Install (on the VPS)
```bash
sudo install -m755 server/monitoring/remote-disk-poll.sh /usr/local/bin/
sudo cp server/monitoring/remote-disk-poll.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now remote-disk-poll.timer
```
Runs as the `lauri` user (needs its SSH config/key + docker access). Every minute.
