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
