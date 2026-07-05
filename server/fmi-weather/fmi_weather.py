#!/usr/bin/env python3
"""Poll FMI open weather observations and republish to MQTT for Telegraf.

Fetches the latest observation for each configured station from the FMI open WFS
service (no API key) every POLL_INTERVAL seconds and publishes JSON to
    decoded/<site>/fmi/<label>
which Telegraf maps into sensor_readings (source='fmi', sensor_id=<label>). FMI
weather observations update roughly every 10 minutes, so ~600 s polling is plenty.

Station identities (which weather station backs which site) reveal location, so the
real stations.json is git-ignored — only this code + stations.example.json are
committed. Copy the example to stations.json and fill it in (see README).

Data source: Finnish Meteorological Institute open data, licensed CC BY 4.0.
"""
import json
import os
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import paho.mqtt.client as mqtt

BROKER = os.environ.get("MQTT_HOST", "mosquitto")
PORT = int(os.environ.get("MQTT_PORT", "1883"))
# Poll fast, publish only on a NEW observation: FMI observes on a 10-min grid and
# publishes each obs a few minutes after the mark; a 60 s poll with change detection
# keeps end-to-end staleness at (FMI publication latency + <=1 poll).
POLL = int(os.environ.get("POLL_INTERVAL", "60"))
CONF = os.environ.get("STATIONS_FILE", "/config/stations.json")
WFS = "https://opendata.fmi.fi/wfs"
BS = "{http://xml.fmi.fi/schema/wfs/2.0}"                    # BsWfs 'simple' feature namespace

# FMI observation parameter name -> sensor_readings column. Extend to add metrics
# (humidity/pressure columns already exist; the config's "parameters" list drives it).
COL = {"temperature": "temperature", "humidity": "humidity", "pressure": "pressure"}


def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def fetch_latest(fmisid, params):
    """Return {fmi_param: (time, value)} for the newest valid sample in the last hour."""
    q = {
        "service": "WFS", "version": "2.0.0", "request": "getFeature",
        "storedquery_id": "fmi::observations::weather::simple",
        "fmisid": str(fmisid), "parameters": ",".join(params),
        "starttime": _iso(time.time() - 3600),
    }
    url = WFS + "?" + urllib.parse.urlencode(q)
    with urllib.request.urlopen(url, timeout=30) as resp:
        root = ET.fromstring(resp.read())
    latest = {}
    for el in root.iter(BS + "BsWfsElement"):
        t = el.findtext(BS + "Time")
        name = el.findtext(BS + "ParameterName")
        val = el.findtext(BS + "ParameterValue")
        if not val or val.strip().lower() in ("nan", ""):
            continue
        try:
            v = float(val)
        except ValueError:
            continue
        if name not in latest or t > latest[name][0]:
            latest[name] = (t, v)
    return latest


def main():
    with open(CONF, encoding="utf-8") as fh:
        stations = json.load(fh)
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="fmi-weather")
    client.connect(BROKER, PORT, keepalive=60)
    client.loop_start()
    print(f"fmi-weather up: {len(stations)} station(s), poll every {POLL}s, "
          "publish on new observation only", flush=True)
    last = {}  # label -> newest observation time already published
    while True:
        for s in stations:
            try:
                latest = fetch_latest(s["fmisid"], s.get("parameters", ["temperature"]))
                if not latest:
                    continue
                # newest observation instant this station has; publish the values
                # belonging to it, stamped with the TRUE observation time ("time" is
                # consumed as the metric timestamp by Telegraf, not stored as a column)
                t_new = max(t for (t, _) in latest.values())
                if t_new <= last.get(s["label"], ""):
                    continue                      # nothing new since last publish
                payload = {COL[k]: v for k, (t, v) in latest.items()
                           if k in COL and t == t_new}
                if payload:
                    payload["time"] = t_new
                    client.publish(f"decoded/{s['site']}/fmi/{s['label']}", json.dumps(payload))
                    last[s["label"]] = t_new
                    print(f"decoded/{s['site']}/fmi/{s['label']} {payload}", flush=True)
            except Exception as exc:  # never let one station kill the loop
                print(f"error {s.get('label')}: {exc}", flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
