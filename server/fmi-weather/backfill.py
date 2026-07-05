#!/usr/bin/env python3
"""One-off: backfill N days of FMI weather history into sensor_readings, as SQL.

Prints SQL on stdout — pipe it to psql. Reads the same git-ignored stations.json as
the poller. Fetches in 24 h chunks (FMI caps a single query window) and writes rows at
their true observation timestamps. Idempotent per station+window: deletes any existing
source='fmi' rows for each label in the covered range before inserting.

    STATIONS_FILE=./stations.json python3 backfill.py 7 \
      | docker exec -i server-timescaledb-1 psql -U postgres -d sensors -v ON_ERROR_STOP=1

Data source: Finnish Meteorological Institute open data, CC BY 4.0.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 7
CONF = os.environ.get("STATIONS_FILE", "/config/stations.json")
WFS = "https://opendata.fmi.fi/wfs"
BS = "{http://xml.fmi.fi/schema/wfs/2.0}"
COL = {"temperature": "temperature", "humidity": "humidity", "pressure": "pressure"}


def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def fetch(fmisid, params, start, end):
    q = {
        "service": "WFS", "version": "2.0.0", "request": "getFeature",
        "storedquery_id": "fmi::observations::weather::simple",
        "fmisid": str(fmisid), "parameters": ",".join(params),
        "starttime": _iso(start), "endtime": _iso(end),
    }
    url = WFS + "?" + urllib.parse.urlencode(q)
    with urllib.request.urlopen(url, timeout=60) as resp:
        root = ET.fromstring(resp.read())
    out = []
    for el in root.iter(BS + "BsWfsElement"):
        t = el.findtext(BS + "Time")
        name = el.findtext(BS + "ParameterName")
        val = el.findtext(BS + "ParameterValue")
        if not val or val.strip().lower() in ("nan", ""):
            continue
        try:
            out.append((t, name, float(val)))
        except ValueError:
            pass
    return out


def main():
    with open(CONF, encoding="utf-8") as fh:
        stations = json.load(fh)
    now = time.time()
    window_start = _iso(now - DAYS * 86400)
    print("BEGIN;")
    for s in stations:
        params = s.get("parameters", ["temperature"])
        label = s["label"].replace("'", "''")
        rows = {}  # obs_time -> {col: value}
        for chunk in range(DAYS):
            end = now - chunk * 86400
            for (t, name, v) in fetch(s["fmisid"], params, end - 86400, end):
                if name in COL:
                    rows.setdefault(t, {})[COL[name]] = v
        print(f"DELETE FROM sensor_readings WHERE source='fmi' AND sensor_id='{label}' "
              f"AND \"time\" >= '{window_start}';")
        for t, cols in sorted(rows.items()):
            names = ",".join(cols.keys())
            vals = ",".join(repr(x) for x in cols.values())
            print(f"INSERT INTO sensor_readings (\"time\",site,source,sensor_id,{names}) "
                  f"VALUES ('{t}','{s['site']}','fmi','{label}',{vals});")
        print(f"-- {s['site']} {s['label']}: {len(rows)} observations")
    print("COMMIT;")


if __name__ == "__main__":
    main()
