#!/usr/bin/env python3
"""Phase 0 — local RuuviTag verification (and later, a pipeline smoke-test).

This is a THROWAWAY verification tool, NOT a real edge node. It exists to answer
"can I even read my tags?" cheaply, before any VPS or edge hardware is involved,
and later to smoke-test the ingestion pipeline once the VPS exists.

Two modes, matching the plan's Phase 0 steps:

  1. Read-only (default) — scan for RuuviTag advertisements, decode Data Format 5
     (RAWv2), and print readings to the console. No MQTT, no VPS dependency.
     This alone answers "do I get RuuviTag data?".

  2. Publish (--mqtt-host …) — additionally forward each advertisement over MQTT
     exactly like a real Ruuvi gateway would: topic `<site>/ruuvi/<mac>`, payload in
     the Ruuvi Gateway JSON format (raw advertisement hex in `data`), which is what
     RuuviBridge's mqtt_listener expects. This is the M4 pipeline smoke test; the
     MQTT password comes from --mqtt-pass, $MQTT_PASS, or a .env file next to this
     script (MQTT_PASS=...), so it never has to appear on a command line.

Cross-platform via `bleak` (works natively on Windows, macOS, Linux/BlueZ).

Examples
--------
    # M0: just confirm the tags are readable, run until Ctrl-C
    python ruuvi_test_publisher.py

    # print one reading per tag, then exit (handy for a quick checkpoint)
    python ruuvi_test_publisher.py --once

    # M4: also publish to the VPS broker (requires paho-mqtt installed)
    python ruuvi_test_publisher.py \
        --mqtt-host metrics.example.com --mqtt-port 8883 --tls \
        --mqtt-user site-test --mqtt-pass '…' --site test
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import struct
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

try:
    from bleak import BleakScanner
except ImportError:  # pragma: no cover - guidance path
    sys.exit(
        "bleak is not installed. Run:  pip install -r requirements.txt\n"
        "(inside scripts/test-publisher/)"
    )

# Ruuvi Innovations Ltd. Bluetooth SIG company identifier.
RUUVI_COMPANY_ID = 0x0499


@dataclass
class Reading:
    """A decoded RuuviTag Data Format 5 measurement.

    Fields are None when the tag reports the format's documented 'invalid' sentinel
    for that field (e.g. no accelerometer, or a value out of range).
    """

    mac: str
    data_format: int
    temperature_c: float | None
    humidity_pct: float | None
    pressure_hpa: float | None
    accel_x_g: float | None
    accel_y_g: float | None
    accel_z_g: float | None
    battery_mv: int | None
    tx_power_dbm: int | None
    movement_counter: int | None
    sequence: int | None
    rssi: int | None

    def as_line(self) -> str:
        def fmt(v, suffix, nd=2):
            return f"{v:.{nd}f}{suffix}" if v is not None else "—"

        return (
            f"{self.mac}  "
            f"T={fmt(self.temperature_c, '°C')}  "
            f"RH={fmt(self.humidity_pct, '%')}  "
            f"P={fmt(self.pressure_hpa, ' hPa', 1)}  "
            f"batt={self.battery_mv if self.battery_mv is not None else '—'}mV  "
            f"seq={self.sequence if self.sequence is not None else '—'}  "
            f"rssi={self.rssi if self.rssi is not None else '—'}"
        )


def _signed(value: int, sentinel: int) -> int | None:
    return None if value == sentinel else value


def decode_df5(payload: bytes, rssi: int | None = None) -> Reading | None:
    """Decode a Ruuvi Data Format 5 (RAWv2) manufacturer-data payload.

    `payload` is the manufacturer-specific data WITHOUT the 2-byte company id
    (bleak already strips the company id and hands us the rest). Returns None if
    this isn't a DF5 payload we can decode.

    Layout (24 bytes, big-endian):
        0      data format (0x05)
        1-2    temperature   int16, 0.005 °C/LSB            (0x8000 = invalid)
        3-4    humidity      uint16, 0.0025 %/LSB           (0xFFFF = invalid)
        5-6    pressure      uint16, 1 Pa/LSB, +50000 offset (0xFFFF = invalid)
        7-8    accel X       int16, 1 mg/LSB                (0x8000 = invalid)
        9-10   accel Y       int16, 1 mg/LSB
        11-12  accel Z       int16, 1 mg/LSB
        13-14  power info    uint16: 11 bits batt (mV above 1.6V), 5 bits tx power
        15     movement ctr  uint8                          (0xFF = invalid)
        16-17  sequence      uint16                         (0xFFFF = invalid)
        18-23  MAC           6 bytes
    """
    if len(payload) < 24 or payload[0] != 0x05:
        return None

    (
        _fmt,
        temp_raw,
        hum_raw,
        pres_raw,
        ax_raw,
        ay_raw,
        az_raw,
        power_raw,
        move_raw,
        seq_raw,
    ) = struct.unpack(">BhHHhhhHBH", payload[:18])
    mac_bytes = payload[18:24]

    temperature = None if temp_raw == -0x8000 else temp_raw * 0.005
    humidity = None if hum_raw == 0xFFFF else hum_raw * 0.0025
    pressure = None if pres_raw == 0xFFFF else (pres_raw + 50000) / 100.0  # -> hPa

    accel_x = None if ax_raw == -0x8000 else ax_raw / 1000.0  # mg -> g
    accel_y = None if ay_raw == -0x8000 else ay_raw / 1000.0
    accel_z = None if az_raw == -0x8000 else az_raw / 1000.0

    batt_raw = power_raw >> 5          # top 11 bits
    tx_raw = power_raw & 0x1F          # low 5 bits
    battery_mv = None if batt_raw == 0x7FF else batt_raw + 1600
    tx_power = None if tx_raw == 0x1F else tx_raw * 2 - 40

    movement = _signed(move_raw, 0xFF)
    sequence = _signed(seq_raw, 0xFFFF)

    mac = ":".join(f"{b:02X}" for b in mac_bytes)

    return Reading(
        mac=mac,
        data_format=5,
        temperature_c=temperature,
        humidity_pct=humidity,
        pressure_hpa=pressure,
        accel_x_g=accel_x,
        accel_y_g=accel_y,
        accel_z_g=accel_z,
        battery_mv=battery_mv,
        tx_power_dbm=tx_power,
        movement_counter=movement,
        sequence=sequence,
        rssi=rssi,
    )


def sensor_id(mac: str) -> str:
    """Stable per-device id used in the topic path. MAC without separators, lower-case."""
    return mac.replace(":", "").lower()


def build_gateway_payload(manufacturer_payload: bytes, rssi: int | None) -> dict:
    """Ruuvi Gateway JSON body — what RuuviBridge's mqtt_listener expects.

    `data` is the raw BLE advertisement hex: flags AD (020106) + one
    manufacturer-specific AD (len, 0xFF, company id 0x0499 little-endian, payload).
    RuuviBridge finds the Ruuvi manufacturer data in there and decodes it itself —
    this script stays a dumb forwarder in publish mode, like a real gateway.
    """
    ad_len = len(manufacturer_payload) + 3  # type byte + 2-byte company id
    data_hex = "020106" + f"{ad_len:02X}" + "FF" + "9904" + manufacturer_payload.hex().upper()
    now = int(time.time())
    return {
        "gw_mac": "00:00:00:00:00:00",  # this test script is not a real gateway
        "rssi": rssi if rssi is not None else 0,
        "aoa": [],
        "gwts": now,
        "ts": now,
        "data": data_hex,
        "coords": "",
    }


def load_dotenv_next_to_script() -> None:
    """Populate os.environ from a `.env` beside this script (KEY=VALUE lines).

    Lets the MQTT password live in a git-ignored file instead of a command line.
    Existing environment variables win.
    """
    env_file = Path(__file__).resolve().parent / ".env"
    if not env_file.is_file():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


async def run(args: argparse.Namespace) -> int:
    publisher = None
    if args.mqtt_host:
        publisher = _make_publisher(args)

    seen: dict[str, Reading] = {}
    last_published_seq: dict[str, int | None] = {}
    stop = asyncio.Event()

    def on_detection(device, adv):
        md = adv.manufacturer_data or {}
        payload = md.get(RUUVI_COMPANY_ID)
        if not payload:
            return  # not a Ruuvi advertisement
        raw = bytes(payload)
        reading = decode_df5(raw, rssi=adv.rssi)
        if reading is None:
            return  # a Ruuvi packet but not DF5 (older format) — ignore for now
        first_time = reading.mac not in seen
        seen[reading.mac] = reading
        print(reading.as_line(), flush=True)

        if publisher is not None:
            # the Windows BLE stack delivers the same advertisement several times;
            # skip re-publishing until the tag's sequence number actually advances
            if reading.sequence is not None and reading.sequence == last_published_seq.get(reading.mac):
                return
            last_published_seq[reading.mac] = reading.sequence
            # forward like a real gateway: raw hex, RuuviBridge does the decoding
            topic = f"{args.site}/ruuvi/{reading.mac}"
            publisher.publish(topic, json.dumps(build_gateway_payload(raw, adv.rssi)), qos=0)

        if args.once and first_time:
            # Stop once we've seen at least one reading from every tag we've found so far.
            # There's no fixed expected count, so we settle after a short quiet period
            # instead — handled by the timeout in the run loop below.
            pass

    scanner = BleakScanner(detection_callback=on_detection)

    # Allow Ctrl-C to break the scan cleanly on all platforms.
    loop = asyncio.get_running_loop()
    try:
        loop.add_signal_handler(signal.SIGINT, stop.set)
    except NotImplementedError:  # Windows selector loop: fall back to KeyboardInterrupt
        pass

    print(
        f"Scanning for RuuviTags (DF5)…  "
        f"{'publishing to MQTT + ' if publisher else ''}"
        f"{'one-shot' if args.once else 'Ctrl-C to stop'}",
        file=sys.stderr,
    )

    await scanner.start()
    try:
        if args.once:
            # Give the radio a few seconds to hear each nearby tag at least once.
            await asyncio.sleep(args.once_seconds)
        else:
            await stop.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await scanner.stop()
        if publisher is not None:
            publisher.loop_stop()
            publisher.disconnect()

    if not seen:
        print(
            "\nNo RuuviTags heard. Checks: is Bluetooth on? are the tags in range and "
            "advertising (DF5)? on Linux, is bluetooth.service running?",
            file=sys.stderr,
        )
        return 1

    print(f"\nHeard {len(seen)} tag(s): {', '.join(sorted(seen))}", file=sys.stderr)
    return 0


def _make_publisher(args: argparse.Namespace):
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        sys.exit(
            "--mqtt-host given but paho-mqtt is not installed.\n"
            "Run:  pip install paho-mqtt   (or: pip install -r requirements.txt)"
        )
    try:  # paho-mqtt 2.x requires an explicit callback API version
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    except AttributeError:  # paho-mqtt 1.x
        client = mqtt.Client()
    password = args.mqtt_pass or os.environ.get("MQTT_PASS")
    if args.mqtt_user:
        client.username_pw_set(args.mqtt_user, password or "")
    if args.tls:
        client.tls_set()  # system CA bundle; the VPS cert is Let's Encrypt (Phase 2)
    client.connect(args.mqtt_host, args.mqtt_port, keepalive=30)
    client.loop_start()
    return client


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Phase 0 RuuviTag verification / pipeline smoke-test."
    )
    p.add_argument(
        "--once",
        action="store_true",
        help="print readings for a few seconds, then exit (for a quick checkpoint)",
    )
    p.add_argument(
        "--once-seconds",
        type=float,
        default=8.0,
        help="how long to scan in --once mode (default: 8)",
    )
    # MQTT publishing — Phase 2+/M4; requires the VPS broker to exist.
    p.add_argument("--mqtt-host", help="Mosquitto host; enables MQTT publishing")
    p.add_argument("--mqtt-port", type=int, default=8883)
    p.add_argument("--mqtt-user")
    p.add_argument("--mqtt-pass", help="or set $MQTT_PASS / MQTT_PASS= in .env beside the script")
    p.add_argument("--tls", action="store_true", help="use TLS for the MQTT connection")
    p.add_argument(
        "--site",
        default="test",
        help="site name used in the topic prefix `<site>/ruuvi/<id>` (default: test)",
    )
    return p.parse_args(argv)


def main() -> int:
    # Emit UTF-8 regardless of the console's default code page (Windows defaults to
    # cp1252, which mangles the °/… characters in our output).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass

    load_dotenv_next_to_script()
    args = parse_args()
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
