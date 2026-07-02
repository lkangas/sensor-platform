# Edge node setup — plan & runbook (M5 / M7)

Everything that happens when you add a real site (home, summer place, …). The
central stack (M0–M4, M6) is already live at `petzval.dy.fi`; an edge node is a
"dumb" box that scans RuuviTags over Bluetooth and forwards them to it. Nothing
central needs redesigning per site — this document is the repeatable procedure.

Read top to bottom once. Then per node it's: **buy → flash → one command → verify.**

---

## 1. What an edge node actually does

```
RuuviTags ──BLE──► [edge node: ruuvi-go-gateway] ──MQTT/TLS 8883──► petzval.dy.fi
                    scan + forward, nothing else        outbound only
```

- Reads BLE advertisements, republishes them **unchanged** (Ruuvi Gateway format,
  raw hex) to `<site>/ruuvi/<mac>` on the VPS broker over TLS.
- All decoding/storage/dashboards stay central. The node keeps no state, needs no
  inbound network, and is disposable — if it dies, you reflash and re-run one
  command.
- Resource need is trivial: ~20 MB RAM, ~10 MB disk. Any Linux box with a BLE
  adapter qualifies.

This is exactly the path the M4 test publisher already proved end-to-end — the
edge node just replaces "Windows laptop running the test script."

---

## 2. Hardware — what to buy (you have not bought yet)

You need **two** nodes (home + summer place). They don't have to match, but
buying two identical ones means one flashing procedure and one spare-parts story.

### Requirements (any candidate must have)
- Runs Linux
- **Bluetooth Low Energy** (built-in, or a USB BLE dongle)
- Always-on power and network at the site

### Recommended, in order

| Option | Profile | Notes |
|--------|---------|-------|
| **Raspberry Pi 4 Model B (2 GB)** | B (Docker) | Best all-rounder. Built-in BT 5.0, wired + Wi-Fi, tons of headroom (can do store-and-forward later). New Pi prices are up in 2026 (DRAM spike) — check the used market. |
| **x86 mini-PC (Intel N100 / used NUC)** | B (Docker) | Rock-solid, great for the summer place if mains power is available. Most need a **USB BLE dongle** (few have built-in BT). Higher idle draw (~6–10 W). |
| **Raspberry Pi 3B / 3B+ / 3A+** | B (Docker) | Built-in BT, ARMv8, Docker-capable. 3A+ has 512 MB / no Ethernet — both fine here. Excellent used-market target. |
| **Raspberry Pi Zero 2 W** | B (Docker) | Spec-ideal (tiny, Wi-Fi+BT, ARMv8). Stock is intermittent — don't plan around getting one fast. |
| Original Pi Zero / Zero W / Pi 1 | **A (binary)** | ARMv6 — Docker images often lack an arm/v6 build, so these use the native-binary profile. Only if you already own one. |

**Avoid** for this: Pi 2B and older (no Bluetooth on any revision without a dongle).

### Don't forget
- **Good microSD (A1/A2, 32 GB+)** and a **known-good power supply**. Undervoltage
  shows up as flaky Wi-Fi/Bluetooth — the worst failure mode at a remote site.
- A case. For the summer place, prefer **wired Ethernet** if available (more
  reliable than Wi-Fi through cabin walls).

### My concrete suggestion
Two **Raspberry Pi 4 (2 GB)** (or two used Pi 3B+ to save money) — identical,
built-in BT, Profile B, and the Pi 4 has enough spare capacity to add
store-and-forward at the summer place later. If you'd rather one bulletproof
always-on box at home, a used N100 mini-PC + a cheap USB BLE dongle is a fine
substitute — tell me and I'll adjust the plan.

> ⚠️ **Summer place, cold-weather caveat:** the node monitors a space you're
> worried will freeze — so the node itself lives in that cold. Most Pis are rated
> 0 °C and up; a truly sub-zero cabin can make an SD-card Pi unreliable in deep
> winter. Keep the node in the least-cold indoor spot, or use a board with an
> industrial temperature range. The freeze **alert** is already built (M6); this
> is about the hardware surviving to send it.

---

## 3. Two deployment profiles

Picked automatically by hardware; everything downstream is identical.

- **Profile B — Docker (default).** x86_64 and ARMv8/ARMv7 (Pi 3-series or better).
  Runs `ghcr.io/scrin/ruuvi-go-gateway` via `edge/docker-compose.yml`.
- **Profile A — native binary + systemd.** ARMv6 only (original Pi Zero/1), where
  Docker images often have no arm/v6 variant. Uses `edge/systemd/ruuvi-gateway.service`
  and a prebuilt binary in `edge/bin/`.

For the hardware recommended above you will use **Profile B**.

---

## 4. One-time server-side prep (per new site)

Done on the VPS before/at provisioning. Files are already staged in the repo for
`home` and `summer`; this is what to actually run.

```bash
ssh lauri@petzval.dy.fi
cd ~/sensor-platform && git pull
cd server

# 4a. create the site's MQTT user (external 8883 listener). Password printed once.
SITE=home                              # or summer
PASS=$(openssl rand -base64 18 | tr -d '/+=')
docker run --rm -v "$PWD/mosquitto:/work" eclipse-mosquitto:2 \
  mosquitto_passwd -b /work/passwd "site-$SITE" "$PASS"
sudo chown 1883:1883 mosquitto/passwd && sudo chmod 600 mosquitto/passwd
docker compose exec mosquitto kill -HUP 1     # reload passwd without downtime
echo "site-$SITE password: $PASS"             # -> put in your password manager

# 4b. start that site's RuuviBridge decoder (config already committed)
#     add the service block below to server/docker-compose.yml first (see note),
#     then:
docker compose up -d ruuvibridge-$SITE
```

**Compose service block** to add to `server/docker-compose.yml` for each site
(mirrors `ruuvibridge-test`):

```yaml
  ruuvibridge-home:                 # and a ruuvibridge-summer copy
    image: ghcr.io/scrin/ruuvibridge:latest
    restart: unless-stopped
    volumes:
      - ./ruuvibridge/config-home.yml:/config.yml:ro
    depends_on:
      - mosquitto
```

The ACL already grants `site-home` → `home/#` and `site-summer` → `summer/#`
(`server/mosquitto/acl`), so a node can only ever write its own site's topics.
The Grafana dashboard's `site` dropdown auto-discovers the new site once rows
arrive — **no dashboard change needed.**

> When you're ready to do this for real, I can add the two compose service blocks
> and walk the VPS steps with you (same approve-each-step flow as before).

---

## 5. Provisioning a node (Profile B) — the runbook

Per node, ~15 minutes of hands-on:

1. **Flash the OS.** Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)** for a
   Pi 3-series+, or Ubuntu Server for x86. In the imager's settings (gear icon)
   pre-set: hostname (e.g. `ruuvi-home`), your **SSH public key**, Wi-Fi (if not
   wired), locale/timezone. This makes it headless from first boot.
2. **First boot + update.** `ssh <user>@ruuvi-home` then
   `sudo apt update && sudo apt full-upgrade -y && sudo reboot`.
3. **Sanity-check Bluetooth sees tags** (catches dongle/driver issues before Docker):
   ```bash
   sudo hcitool lescan   # should list device addresses; Ctrl-C to stop
   ```
4. **Bootstrap** — one command, from the repo's `scripts/`:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/lkangas/sensor-platform/main/scripts/bootstrap-edge.sh \
     | MQTT_PASS='<the site password from step 4a>' bash -s -- home site-home docker
   ```
   or clone first and run `scripts/bootstrap-edge.sh home site-home docker`
   (it prompts for the password if `$MQTT_PASS` isn't set — never pass it on the
   visible command line). The script: clones the repo, writes `edge/.env`, renders
   `config.yml` from the template, installs Docker if missing, and starts the
   gateway with `restart: unless-stopped` so it survives reboots.

That's it. The node now scans and forwards.

### Profile A (ARMv6) differences
Only if you're using an original Pi Zero/1: flash **32-bit** Pi OS Lite, place the
matching `ruuvi-gateway-armv6l` binary in `edge/bin/` (cross-compile with
`GOOS=linux GOARCH=arm GOARM=6 go build`), and run the bootstrap with `binary` as
the last argument. It installs the systemd unit instead of Docker.

---

## 6. Verify the site is live (the M5 checkpoint)

From the VPS (or via me, read-only):

```bash
# raw packets arriving from the node
mosquitto_sub -h localhost -t 'home/ruuvi/#' -C 3
# decoded values coming out of RuuviBridge
mosquitto_sub -h localhost -t 'decoded/home/ruuvi/#' -C 3
# rows landing, tagged with the site
docker compose exec timescaledb psql -U postgres -d sensors \
  -c "SELECT count(*), max(time) FROM sensor_readings WHERE site='home';"
```

Then open Grafana → **Sensors — Overview**, pick `home` in the **Site** dropdown,
and confirm curves. Success = raw → decoded → rows → dashboard, same chain M4
proved.

---

## 7. Summer place — the extra considerations

The home node is the easy one. The summer place has three real differences:

1. **Flaky internet.** MQTT tolerates latency and auto-reconnects, so brief drops
   just cause **gaps** in the data. `ruuvi-go-gateway` forwards in real time and
   does **not** buffer across long outages — if you lose the link for hours, those
   hours are simply missing. If gap-free history matters, add a store-and-forward
   step (local buffer + replay on reconnect); a Pi 4 has the capacity for it. Say
   the word and I'll design that as a follow-up. Otherwise: accept the gaps.
   - Note: the **"sensor offline"** alert (M6) will fire during a long internet
     outage even though the tags are fine — it can't tell "tag dead" from "link
     down." The gateway's LWT (`<site>/ruuvi/gw_status`) distinguishes them; we can
     wire a smarter alert later.
2. **No public IP / behind NAT.** You can't SSH in directly. Install **Tailscale**
   on the node (and your laptop) — then the node is reachable at a stable tailnet
   address from anywhere, for SSH and updates, with no port-forwarding. The MQTT
   data path needs no inbound access (it's outbound to the VPS), so Tailscale is
   purely for *your* management access.
3. **Power & cold.** See the cold-weather caveat in §2. Use a quality PSU; consider
   a small UPS if cabin power flickers (undervoltage → dropped BT). The freeze
   alert is the whole point of this site, so the node must stay powered through the
   conditions it's watching.

---

## 8. Scaling beyond two nodes (M7 / M8, later)

- **Tier 1 — bootstrap script (now):** what §5 uses. Good to a handful of nodes.
- **Tier 2 — Ansible (at ~3+ nodes):** manage the fleet from one command;
  per-node site + vault-encrypted credentials in `ansible/host_vars/`. Scaffolding
  is stubbed in `ansible/`.
- **Tier 3 — golden image:** clone one perfected SD card, change hostname + `.env`
  per node. Fast, but Ansible stays cleaner for ongoing changes.
- **Keeping nodes current:** Watchtower (auto-pull images) or drive
  `docker compose pull && up -d` from Ansible.

---

## 9. Quick reference — files this involves

| File | Role |
|------|------|
| `edge/.env.example` | per-node config template (copy to `.env`) |
| `edge/ruuvi-go-gateway/config.yml.template` | gateway config; bootstrap renders `config.yml` (git-ignored) |
| `edge/docker-compose.yml` | Profile B runtime |
| `edge/systemd/ruuvi-gateway.service` | Profile A runtime |
| `edge/bin/` | Profile A prebuilt binaries (per arch) |
| `scripts/bootstrap-edge.sh` | the one-command setup |
| `server/ruuvibridge/config-{home,summer}.yml` | per-site decoders (staged) |
| `server/mosquitto/acl` | per-site write permissions (home + summer staged) |

---

## 10. TL;DR of what to do next

1. **Buy** two nodes (see §2 — my pick: 2× Pi 4 2 GB, or ask me to tailor).
2. When they arrive, tell me — I'll do the server-side prep (§4) with you and hand
   you the exact bootstrap command per node.
3. Flash, run one command, verify. Home first (easy), then summer place with
   Tailscale.
