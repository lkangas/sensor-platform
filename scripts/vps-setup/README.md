# vps-setup — M1 record & artifacts

What was done to the VPS in M1 (Phase 1), so the box can be rebuilt from this
document. Performed 2026-07-02 on a Hetzner CX23-class server, Helsinki (hel1),
Ubuntu 26.04 LTS, host `sensors`, IP `95.216.138.33`, name **petzval.dy.fi**.

## Users & SSH

- Non-root sudo user `lauri` (passwordless sudo — the account is key-only, no
  password exists; SSH key = the same ed25519 key used locally).
- `/etc/ssh/sshd_config.d/10-hardening.conf`:
  ```
  PermitRootLogin no
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  X11Forwarding no
  ```

## Firewall (ufw) — default deny incoming

| Port | Why |
|------|-----|
| 22/tcp | SSH |
| 80/tcp | ACME HTTP-01 + HTTP→HTTPS redirect (Caddy; added beyond the plan's 22/443/8883 list) |
| 443/tcp | HTTPS (Grafana via Caddy) |
| 8883/tcp | MQTT over TLS |

Postgres (5432), Grafana (3000), plain MQTT (1883) are never exposed — internal
Docker network only.

Also: `fail2ban` (default sshd jail) and `unattended-upgrades` enabled.

### fail2ban — MQTT brute-force jail (`fail2ban/`)

Protects the public 8883 listener. Install:

```bash
sudo cp fail2ban/action-iptables-docker-multiport.conf /etc/fail2ban/action.d/iptables-docker-multiport.conf
sudo cp fail2ban/filter-mosquitto-docker.conf          /etc/fail2ban/filter.d/mosquitto-docker.conf
sudo cp fail2ban/jail-mosquitto.local                  /etc/fail2ban/jail.d/mosquitto.local
sudo systemctl restart fail2ban
```

- Mosquitto logs to **journald** (compose `logging.driver: journald`); the filter
  reads `CONTAINER_NAME=server-mosquitto-1` and matches mosquitto 2.x
  `disconnected: not authorised` lines (they include the source IP).
- 5 failures / 10 min → 1 h ban, **port 8883 only** (SSH/HTTPS unaffected).
- Bans land in the **DOCKER-USER** chain via the custom action — docker-published
  ports are DNAT'd through FORWARD and bypass INPUT, so a stock INPUT ban does
  nothing here. The inline `chain=` override was not honored on this host; the
  chain is pinned in the action's `[Init]` instead. Verified end-to-end: a
  brute-forcing IP gets 8883 blackholed while SSH stays up.
- `fail2ban-client status mosquitto-docker` shows bans;
  `... set mosquitto-docker unbanip <ip>` clears one.

## Docker

Installed via get.docker.com (Engine 29.x + compose plugin v5.x); `lauri` in the
`docker` group.

## dy.fi dynamic DNS

dy.fi only serves Finnish IPs (hence Helsinki DC) and expires a name after
7 days without a refresh. The refresh **must originate from the VPS** — dy.fi
binds the name to the request's source IP.

- `dyfi-update` → `/usr/local/sbin/dyfi-update` (mode 755)
- `dyfi-update.service` + `dyfi-update.timer` → `/etc/systemd/system/`,
  `systemctl enable --now dyfi-update.timer` (runs 15 min after boot, then every
  5 days)
- Credentials: `/etc/dyfi.netrc` (root:600, **never in git**):
  `machine www.dy.fi login <email> password <password>`

## Checkpoint (passed)

- `docker run --rm hello-world` works as `lauri` without sudo
- `dig +short petzval.dy.fi` → `95.216.138.33` from an external network
