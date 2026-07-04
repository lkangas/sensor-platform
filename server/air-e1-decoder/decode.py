#!/usr/bin/env python3
"""Decode Ruuvi Air data format 0xE1 (BT5 extended-advertisement) payloads that
RuuviBridge does not decode, and republish the extra fields into the
decoded/<site>/ruuvi/<mac> convention Telegraf already consumes.

Reception is already handled upstream: the edge publisher forwards *raw* 0x0499
manufacturer payloads (both DF6 and E1) to <site>/ruuvi/<mac>. RuuviBridge decodes DF6
(temp/hum/pressure/PM2.5/CO2/VOC/NOx); this service fills the E1-only gap — chiefly
PM1.0/PM4.0/PM10.0 and a higher-resolution PM2.5.

Offsets are verified byte-for-byte against this deployment's live E1 payloads. Notes:
  * The shipping Ruuvi Air has no light sensor: luminosity is the 0xFFFFFF sentinel, so
    lux stays NULL — not published here.
  * VOC/NOx are intentionally left to the DF6 decode (their E1 flags-byte encoding is not
    verified here); this publishes only fields it can decode with certainty.
  * Only E1 is acted on; DF6 for the same MAC is left to RuuviBridge.
"""
import json
import os

import paho.mqtt.client as mqtt

BROKER = os.environ.get("MQTT_HOST", "mosquitto")
PORT = int(os.environ.get("MQTT_PORT", "1883"))
RUUVI_CID = 0x0499  # Ruuvi Innovations Ltd Bluetooth company id


def ad_structures(data):
    """Yield (ad_type, value) for each BLE advertising-data structure."""
    i = 0
    while i < len(data):
        length = data[i]
        if length == 0 or i + 1 + length > len(data):
            break
        yield data[i + 1], data[i + 2:i + 1 + length]
        i += 1 + length


def ruuvi_manufacturer_payload(data):
    for ad_type, val in ad_structures(data):
        # 0xFF = manufacturer-specific; first two bytes are the company id (little-endian)
        if ad_type == 0xFF and len(val) >= 2 and (val[0] | (val[1] << 8)) == RUUVI_CID:
            return val[2:]
    return None


def u16(b, o):
    return (b[o] << 8) | b[o + 1]


def decode_e1(p):
    """p starts with 0xE1. Returns the fields decoded with certainty (invalids dropped)."""
    if len(p) < 17:
        return {}
    out = {}
    t = u16(p, 1)
    if t != 0x8000:  # 0x8000 = invalid
        out["temperature"] = round((t - 0x10000 if t >= 0x8000 else t) * 0.005, 3)
    h = u16(p, 3)
    if h != 0xFFFF:
        out["humidity"] = round(h * 0.0025, 3)
    pr = u16(p, 5)
    if pr != 0xFFFF:
        out["pressure"] = pr + 50000  # Pa
    for name, off in (("pm1p0", 7), ("pm2p5", 9), ("pm4p0", 11), ("pm10p0", 13)):
        v = u16(p, off)
        if v != 0xFFFF:
            out[name] = round(v * 0.1, 1)  # ug/m3
    c = u16(p, 15)
    if c != 0xFFFF:
        out["co2"] = c  # ppm
    return out


def on_connect(client, userdata, flags, reason_code, properties=None):
    print(f"connected: {reason_code}; subscribing +/ruuvi/#", flush=True)
    client.subscribe("+/ruuvi/#")  # raw site topics only (not decoded/#)


def on_message(client, userdata, msg):
    try:
        parts = msg.topic.split("/")
        if len(parts) < 3 or parts[1] != "ruuvi":
            return
        site, mac = parts[0], parts[2]
        raw = json.loads(msg.payload).get("data")
        if not raw:
            return
        payload = ruuvi_manufacturer_payload(bytes.fromhex(raw))
        if not payload or payload[0] != 0xE1:
            return  # only E1; RuuviBridge handles DF6
        decoded = decode_e1(payload)
        if not decoded:
            return
        decoded["mac"] = mac
        decoded["data_format"] = "E1"
        client.publish(f"decoded/{site}/ruuvi/{mac}", json.dumps(decoded))
    except Exception as exc:  # never let one bad frame kill the loop
        print(f"decode error on {msg.topic}: {exc}", flush=True)


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="air-e1-decoder")
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(BROKER, PORT, keepalive=60)
    client.loop_forever()


if __name__ == "__main__":
    main()
