# Remote host poll (agentless, edge-side)

SSH-polls host metrics out of boxes that are **too weak or too locked-down to run the
[host-metrics agent](../host-metrics/)** — the motivating case is a Raspberry Pi Zero W
that is nearly saturated streaming audio and will soon run an overlayfs read-only root.
A stronger node on the same LAN runs this poller, reads `/proc` + `/sys` over SSH, and
publishes the same `<site>/host/<node>` JSON the agent would — so the target appears on
the Perf board like any other node. **Nothing is installed or written on the target.**

This is the third of three host-metrics mechanisms:

| | runs on | reaches target via | use when |
|---|---|---|---|
| [`edge/host-metrics/`](../host-metrics/) | the node itself | — | node can afford an agent (richest metrics) |
| [`server/monitoring/`](../../server/monitoring/) | the platform VPS | SSH from the VPS | target reachable from the VPS, must stay clean |
| **this** | a site's edge node | SSH on the site LAN | target only reachable on the LAN, and/or so weak every cycle counts |

## Why it's cheap for the target

- **One multiplexed SSH connection** (`ControlMaster`/`ControlPersist 15m`, kept warm by
  the polls): the expensive key exchange happens once, after which each poll is just a
  new channel on the open connection. The target holds a single idle `sshd` — a few MB
  RAM, ~0 CPU.
- **No sampling sleep on the target**: `cpu_pct` is computed from the `/proc/stat` delta
  *between* polls, so it's a true average over the whole interval (more representative
  than a 1 s sample) and the remote command returns immediately.
- **One short remote command** (~15 file reads, POSIX sh); all parsing happens on the
  polling node. Default interval 120 s.

## Fields

`cpu_pct`, `temperature`, `cpu_load1`, `cpu_mhz`, `mem_pct`, `disk_pct`, `wifi_rssi`,
`throttled` — each omitted when the target doesn't expose its source, same contract as
the agent. Note on `throttled`: `vcgencmd` usually isn't usable over a plain SSH account
(`/dev/vcio*` is often root-only), so this reads the `rpi_volt` hwmon's live
**under-voltage flag** (world-readable) instead. That is exactly the LSB of the vcgencmd
bitmask: `0` healthy, `1` under-voltage *right now* — but the other bitmask bits
(frequency-capped, throttled, "has occurred" history) are not reported.

## Target prerequisites

Only two, both of which live in the base image and therefore survive an overlayfs root:

1. key-only SSH login for the polling user (an `authorized_keys` line), and
2. an entry in the **polling user's** git-ignored `~/.ssh/config` mapping the alias to
   the real user/hostname/key — nothing identifying is committed.

## Install (on the polling edge node)

Requires `mosquitto-clients`; reuses `edge/.env` (SITE + MQTT creds). Add the targets to
`edge/.env` (git-ignored): space-separated `<node>[:<ssh-alias>]`, alias defaulting to
the node name, e.g.

```bash
REMOTE_TARGETS="micpi"            # node id on the Perf board AND ~/.ssh/config alias
# REMOTE_POLL_INTERVAL=120        # seconds, the default
```

Then:

```bash
chmod +x ~/sensor-platform/edge/remote-host-poll/poll-remote-hosts.sh
mkdir -p ~/.config/systemd/user
cp ~/sensor-platform/edge/remote-host-poll/remote-host-poll.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now remote-host-poll
sudo loginctl enable-linger "$USER"   # keep it running across reboots/without login
```

Check: `systemctl --user status remote-host-poll` (it logs one line per publish failure /
unreachable target only), and on the VPS `mosquitto_sub -t '+/host/#' -v` or the Perf
board — the node auto-appears on every panel it has data for; no dashboard edits needed.

Config knobs (env): `REMOTE_TARGETS`, `REMOTE_POLL_INTERVAL` (default 120 s),
`REMOTE_POLL_ENV` (path to the `.env`, default `edge/.env` relative to the repo).
