# Hue collector (DRAFT — not deployed)

Logs Philips Hue data into the platform for analysis: **motion events and remote-control
button presses** (the automation-mining signals), plus **temperature, illuminance (lux)
and battery** from the motion sensors — and, with `LOG_LIGHTS=1` (the default), the
**state of every light/plug**: on/off (0/1), brightness %, colour temperature (mirek).
Set `LOG_LIGHTS=0` in the `.env` to stop light logging (e.g. after a triage period);
light events are partial, so rows carry only the sub-fields that changed.

Architecture: the bridge is LAN-only, so this runs on the **home edge node** and pushes
`{site}/hue/{device-uuid}` over the external MQTTS listener (same pattern + credentials
as `edge/host-metrics`). It listens to the bridge's CLIP v2 **server-sent event stream**
(change-driven; gentle on the bridge) with a periodic snapshot of the continuous metrics
as a heartbeat. One `sensor_id` per physical device: a motion sensor's motion/temp/lux/
battery share an id, like a RuuviTag's metrics.

## Config (`.env`, git-ignored)

```
HUE_BRIDGE=<bridge LAN IP>
HUE_KEY=<application key from pairing>   # credential — private store, like the MQTT pass
SITE=home
MQTT_HOST=<the VPS>
MQTT_PORT=8883
MQTT_USER=<site user> / MQTT_PASS=<site pass>
SNAPSHOT_INTERVAL=900
```

## Server-side pieces required before first deploy

1. **Migration `server/db/migrations/007_hue_columns.sql`** (drafted): adds `motion`
   (0/1), `event` (text), `battery_pct`. Re-apply `004_calibration.sql` afterwards —
   `sensor_readings_cal` freezes its column list at CREATE time.
2. **Telegraf** (`server/telegraf/telegraf.conf`) — three edits on the shared consumer:
   * `topics`: add `"+/hue/+"`
   * a topic_parsing block: `topic = "+/hue/+"` / `tags = "site/source/sensor_id"`
   * `json_string_fields`: add `"event"` (booleans/strings are dropped by the JSON
     parser unless whitelisted — which is also why motion is published as 0/1)
   * `fieldinclude` in outputs.postgresql: add `"motion", "event", "battery_pct"`
     (`temperature`/`lux` are already whitelisted)
   then `docker compose restart telegraf`.

## Dashboards / analysis notes

* Hue device ids are UUIDs (no colons) → they cannot leak into the tag panels'
  unlisted-tag branch. Panels/queries select them via `source='hue'`.
* Events (`motion`, `event`) are point-in-time rows — query raw, don't average; the 1-min
  aggregate ignores them by design. Lux/temperature could be added to the aggregate later
  if Hue curves are wanted on long-window panels.
* Device names flow into `sensor_name` (DB only — same privacy model as tag names:
  fine in Grafana, never in the repo).

## Probe-verified (live bridge + event capture, 2026-07-06)

* motion / temperature / light_level use the `*_report` nesting (direct fields also
  present when valid; disabled sensors omit values entirely — handled).
* button events expose `button_report.event` + `last_event` but **no `control_id`** — the
  event only carries the button resource id, hence the startup button-id→control_id map.
* Event vocabulary confirmed: initial_press, repeat, short_release, long_release, long_press.
* Lux formula and SSE framing (`data:` lines of update arrays) confirmed.
* Light state is CHATTY (hundreds of events in minutes under dynamic scenes) — another
  reason light logging stays an explicit opt-in extension.
