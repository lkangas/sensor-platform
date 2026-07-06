#!/usr/bin/env python3
"""DRAFT — Hue Bridge collector: CLIP v2 event stream -> MQTT -> sensor_readings.

Runs on the HOME edge node (the bridge is LAN-only). Subscribes to the bridge's
server-sent event stream and publishes per-device JSON to <site>/hue/<device-uuid>
over the platform's external MQTTS listener (same site credentials as host-metrics).
Telegraf maps site/source/sensor_id from the topic; see README for the telegraf and
migration (007) pieces this pairs with.

What it emits (fields chosen to be Telegraf-JSON-parser-safe: numbers + whitelisted
strings only — booleans are sent as 0/1 because the parser drops JSON booleans):
    temperature   {"name": ..., "temperature": 21.34}         motion sensors, ~5 min cadence
    light_level   {"name": ..., "lux": 123.5}                 motion sensors (log-encoded -> lux)
    device_power  {"name": ..., "battery_pct": 87}            sensors + remotes
    motion        {"name": ..., "motion": 1}                  event-driven (0 on clear)
    button        {"name": ..., "event": "b2:short_release"}  event-driven, all remotes
Light/plug state is deliberately NOT logged in v1 — add a 'light' branch in decode()
if wanted for automation mining later.

Config via env: HUE_BRIDGE, HUE_KEY (or HUE_KEY_FILE), SITE (default home),
MQTT_HOST/MQTT_PORT/MQTT_USER/MQTT_PASS (TLS), SNAPSHOT_INTERVAL (s, default 900).

ASSUMPTIONS TO VERIFY AT PROBE TIME (public-docs based, untested against this bridge):
  * button events expose button_report.event (newer fw) or last_event (older) and
    metadata.control_id for which button — both handled below, verify shapes.
  * motion events may nest under motion.motion or motion.motion_report.motion.
  * light_level raw -> lux: 10^((raw-1)/10000).
  * SSE data lines are JSON arrays of {type:'update', data:[resource,...]}.
"""
import json
import os
import ssl
import threading
import time
import urllib.request

import paho.mqtt.client as mqtt

BRIDGE = os.environ["HUE_BRIDGE"]
KEY = os.environ.get("HUE_KEY") or open(os.environ["HUE_KEY_FILE"]).read().strip()
SITE = os.environ.get("SITE", "home")
SNAPSHOT = int(os.environ.get("SNAPSHOT_INTERVAL", "900"))
CTX = ssl._create_unverified_context()   # bridge cert is self-signed

devices = {}    # service-uuid -> {"dev": device-uuid, "name": str}
buttons = {}    # button-resource-uuid -> control_id (1..4) — SSE button events carry NO
                # metadata.control_id (verified against live events 2026-07-06), only the
                # resource id; the mapping must come from the full resource at startup.


def hue_get(path, timeout=20):
    r = urllib.request.Request(f"https://{BRIDGE}{path}")
    r.add_header("hue-application-key", KEY)
    with urllib.request.urlopen(r, context=CTX, timeout=timeout) as resp:
        return json.loads(resp.read())


def load_device_map():
    """service-uuid -> owning device uuid + human name (names stay in the DB, not git)."""
    m = {}
    for d in hue_get("/clip/v2/resource/device").get("data", []):
        name = d.get("metadata", {}).get("name", "")
        for s in d.get("services", []):
            m[s["rid"]] = {"dev": d["id"], "name": name}
    devices.clear()
    devices.update(m)
    b = {r["id"]: r.get("metadata", {}).get("control_id", 0)
         for r in hue_get("/clip/v2/resource/button").get("data", [])}
    buttons.clear()
    buttons.update(b)
    print(f"device map: {len(devices)} services across "
          f"{len({v['dev'] for v in devices.values()})} devices; "
          f"{len(buttons)} buttons", flush=True)


def decode(item):
    """One CLIP v2 resource (from an event or a snapshot) -> payload dict, or None."""
    t = item.get("type")
    if t == "temperature":
        rep = item.get("temperature", {})
        val = rep.get("temperature_report", {}).get("temperature", rep.get("temperature"))
        return None if val is None else {"temperature": round(float(val), 2)}
    if t == "light_level":
        rep = item.get("light", {})
        raw = rep.get("light_level_report", {}).get("light_level", rep.get("light_level"))
        if raw is None:
            return None
        return {"lux": round(10 ** ((int(raw) - 1) / 10000), 1)}
    if t == "motion":
        rep = item.get("motion", {})
        val = rep.get("motion_report", {}).get("motion", rep.get("motion"))
        return None if val is None else {"motion": 1 if val else 0}
    if t == "device_power":
        lvl = item.get("power_state", {}).get("battery_level")
        return None if lvl is None else {"battery_pct": int(lvl)}
    if t == "button":
        rep = item.get("button", {})
        ev = rep.get("button_report", {}).get("event") or rep.get("last_event")
        if not ev:
            return None
        ctl = buttons.get(item.get("id")) or item.get("metadata", {}).get("control_id", 0)
        return {"event": f"b{ctl}:{ev}"}
    return None


def publish(client, item):
    payload = decode(item)
    if not payload:
        return
    ref = devices.get(item.get("id"))
    dev = ref["dev"] if ref else item.get("owner", {}).get("rid", item.get("id"))
    if ref and ref["name"]:
        payload["name"] = ref["name"]
    client.publish(f"{SITE}/hue/{dev}", json.dumps(payload), qos=0)


def snapshot_loop(client):
    """Heartbeat for the continuous metrics: distinguishes 'no change' from 'collector
    dead'. Runs once at startup too, so temp/lux/battery appear immediately on deploy."""
    while True:
        try:
            for rtype in ("temperature", "light_level", "device_power"):
                for item in hue_get(f"/clip/v2/resource/{rtype}").get("data", []):
                    publish(client, item)
        except Exception as exc:
            print(f"snapshot error: {exc}", flush=True)
        time.sleep(SNAPSHOT)


def event_loop(client):
    backoff = 1
    while True:
        try:
            req = urllib.request.Request(f"https://{BRIDGE}/eventstream/clip/v2")
            req.add_header("hue-application-key", KEY)
            req.add_header("Accept", "text/event-stream")
            with urllib.request.urlopen(req, context=CTX, timeout=120) as resp:
                print("event stream connected", flush=True)
                backoff = 1
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    for ev in json.loads(line[5:]):
                        for item in ev.get("data", []):
                            if item.get("type") == "device":
                                load_device_map()   # renames / new devices
                            else:
                                publish(client, item)
        except Exception as exc:
            # Idle read timeouts are ROUTINE, not failures: the bridge sends no SSE
            # keepalives (verified 2026-07-06 — one ': hi' at connect, then silence when
            # nothing happens), so a quiet house times the read out every couple of
            # minutes. Reconnect immediately and quietly; save backoff + map reload for
            # real errors.
            idle = isinstance(exc, TimeoutError) or isinstance(
                getattr(exc, "reason", None), TimeoutError)
            if idle:
                continue
            print(f"event stream dropped ({exc}); retry in {backoff}s", flush=True)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            try:
                load_device_map()
            except Exception:
                pass


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"hue-collector-{SITE}")
    client.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASS"])
    client.tls_set()   # public CA (the platform's Let's Encrypt cert)
    client.connect(os.environ.get("MQTT_HOST", "vps.example.com"),
                   int(os.environ.get("MQTT_PORT", "8883")), keepalive=60)
    client.loop_start()
    load_device_map()
    threading.Thread(target=snapshot_loop, args=(client,), daemon=True).start()
    event_loop(client)


if __name__ == "__main__":
    main()
