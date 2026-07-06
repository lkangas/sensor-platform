# SSH exposure monitor

Publishes how much SSH traffic (attacks + your own logins) and fail2ban activity a node
sees, so it shows up in Grafana next to the sensors — useful when a node's SSH port is
exposed to the internet. Same MQTT→Telegraf→`sensor_readings` path as the other feeds;
`source='security'`, `sensor_id=<node>`.

**Two data sources, on purpose:**
- **journald** (`journalctl -u ssh`) — every auth attempt: `ssh_failed` (bad passwords /
  interval), `ssh_accepted` (successful logins / interval), `ssh_ips` (distinct source IPs
  behind the failures / interval — breadth of the attack).
- **fail2ban** (`fail2ban-client status sshd`) — `f2b_banned` (currently banned) and
  `f2b_banned_total` (cumulative). Complements journald: journald = who's knocking,
  fail2ban = who got shut out.

Runs as a **root** systemd service (the full journal and the fail2ban socket are both
root-only). It's a shell loop mirroring `edge/host-metrics/publish-host-metrics.sh`.

## Install (on the node, needs sudo)

```bash
sudo apt install -y mosquitto-clients                 # host lacks it if only containers publish
sudo cp edge/ssh-monitor/ssh-monitor.sh /usr/local/bin/ && sudo chmod 755 /usr/local/bin/ssh-monitor.sh
sudo install -m 600 edge/.env /etc/ssh-monitor.env    # reuse the site's MQTT creds
sudo cp edge/ssh-monitor/ssh-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ssh-monitor
journalctl -u ssh-monitor -f                          # watch it publish
```

Server side (already applied once): migration `009_security_columns.sql` adds the five
columns, Telegraf whitelists `+/security/+`, and the **Security** dashboard renders them.
Config knobs (in `/etc/ssh-monitor.env`): `SSH_MONITOR_INTERVAL` (default 60 s),
`SSH_UNIT` (default `ssh`), `HOST_NODE`.
