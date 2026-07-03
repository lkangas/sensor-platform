#!/usr/bin/env python3
"""Ruuvi BLE publisher — Phase 0 verification tool AND the Profile C edge runtime.

Started life as the throwaway Phase 0 "can I even read my tags?" script; promoted to
double as **edge Profile C**: a BLE scanner for nodes that must share their Bluetooth
adapter with a desktop (keyboard/mouse on BlueZ). Unlike ruuvi-go-gateway, which
seizes the raw HCI socket and fights bluetoothd for the radio, this scans *through*
BlueZ (bleak -> D-Bus) — the same cooperative path the desktop's own peripherals use.
See edge/ble-publisher/ for the supervised container deployment.

Modes:

  1. Read-only (default) — scan for Ruuvi advertisements, decode Data Format 5
     (RAWv2), and print readings to the console. No MQTT, no VPS dependency.

  2. Publish (--mqtt-host, or env MQTT_HOST) — forward each Ruuvi advertisement over
     MQTT exactly like a real Ruuvi gateway: topic `<site>/ruuvi/<mac>`, payload in
     the Ruuvi Gateway JSON format (raw advertisement hex in `data`), which is what
     RuuviBridge's mqtt_listener expects. ALL Ruuvi data formats are forwarded
     (DF5 tags, DF6/E1 Ruuvi Air, …) — decoding stays server-side in RuuviBridge;
     DF5 is decoded locally only for console display. The MQTT password comes from
     --mqtt-pass, $MQTT_PASS, or a .env beside this script — never the command line.

Config precedence: CLI args override environment variables (MQTT_HOST, MQTT_PORT,
MQTT_USER, MQTT_PASS, SITE), which override the .env file beside the script.

Cross-platform via `bleak` (works natively on Windows, macOS, Linux/BlueZ).

Examples
--------
    # M0: just confirm the tags are readable, run until Ctrl-C
    python ruuvi_test_publisher.py

    # print one reading per tag, then exit (handy for a quick checkpoint)
    python ruuvi_test_publisher.py --once

    # M4 smoke test / manual publish run
    python ruuvi_test_publisher.py \
        --mqtt-host metrics.example.com --mqtt-port 8883 --tls \
        --mqtt-user site-test --mqtt-pass '…' --site test

    # Profile C service mode (config from env; exit 3 for supervisor restart if the
    # BLE scan goes silent — e.g. the adapter was reset under us)
    MQTT_HOST=… MQTT_USER=site-home MQTT_PASS=… SITE=home \
        python ruuvi_test_publisher.py --quiet --tls --stale-exit-seconds 180
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

    seen: dict[str, int] = {}              # mac -> data-format byte
    last_payload: dict[str, bytes] = {}    # mac -> last forwarded payload
    published_count = 0
    liveness = {"t": time.monotonic()}     # last time ANY advertisement arrived
    rc = {"code": 0}
    stop = asyncio.Event()

    def on_detection(device, adv):
        liveness["t"] = time.monotonic()   # any device counts: proves the scan is alive
        md = adv.manufacturer_data or {}
        payload = md.get(RUUVI_COMPANY_ID)
        if not payload:
            return  # not a Ruuvi advertisement
        raw = bytes(payload)
        reading = decode_df5(raw, rssi=adv.rssi)
        # Topic identity: DF5 embeds the tag's own MAC in the payload; other Ruuvi
        # formats (DF6/E1 from a Ruuvi Air) don't, so use the advertisement's source
        # address — same thing a real gateway reports.
        mac = reading.mac if reading is not None else (device.address or "").upper()
        if not mac:
            return
        first_time = mac not in seen
        seen[mac] = raw[0]
        if args.quiet:
            if first_time:
                print(f"tag discovered: {mac} (format 0x{raw[0]:02X})", file=sys.stderr, flush=True)
        elif reading is not None:
            print(reading.as_line(), flush=True)
        else:
            print(f"{mac}  df=0x{raw[0]:02X}  {len(raw)}B  rssi={adv.rssi}", flush=True)

        if publisher is not None:
            # BLE stacks deliver the same advertisement many times; forward only when
            # the payload changed. For DF5 this equals the old seq-based dedup (seq is
            # in the payload); for other formats it works without knowing the layout.
            if last_payload.get(mac) == raw:
                return
            last_payload[mac] = raw
            # forward like a real gateway: raw hex, RuuviBridge does the decoding
            topic = f"{args.site}/ruuvi/{mac}"
            publisher.publish(topic, json.dumps(build_gateway_payload(raw, adv.rssi)), qos=0)
            nonlocal published_count
            published_count += 1

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

    async def heartbeat():
        # keeps a long-running quiet log alive and diagnosable
        while True:
            await asyncio.sleep(900)
            print(
                f"heartbeat: {len(seen)} tag(s), {published_count} published, "
                f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}",
                file=sys.stderr, flush=True,
            )

    hb = asyncio.create_task(heartbeat()) if args.quiet else None

    async def scan_liveness_watch():
        # If BlueZ stops delivering advertisements entirely (adapter reset, powered
        # off, bluetoothd restarted), exit non-zero so the supervisor (container
        # restart policy / systemd) recycles us. Deliberately does NOT power the
        # adapter on: on a desktop node the radio belongs to the user first.
        while True:
            await asyncio.sleep(5)
            quiet_for = time.monotonic() - liveness["t"]
            if quiet_for > args.stale_exit_seconds:
                print(
                    f"no BLE advertisements for {quiet_for:.0f}s — "
                    "exiting for supervisor restart",
                    file=sys.stderr, flush=True,
                )
                rc["code"] = 3
                stop.set()
                return

    watch = (
        asyncio.create_task(scan_liveness_watch())
        if (args.stale_exit_seconds > 0 and not args.once)
        else None
    )

    try:
        await scanner.start()
    except Exception as exc:  # adapter off/absent, D-Bus unreachable, …
        print(f"BLE scan could not start: {exc}", file=sys.stderr, flush=True)
        if hb is not None:
            hb.cancel()
        if watch is not None:
            watch.cancel()
        if publisher is not None:
            publisher.loop_stop()
            publisher.disconnect()
        return 4

    try:
        if args.once:
            # Give the radio a few seconds to hear each nearby tag at least once.
            await asyncio.sleep(args.once_seconds)
        else:
            await stop.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        if hb is not None:
            hb.cancel()
        if watch is not None:
            watch.cancel()
        await scanner.stop()
        if publisher is not None:
            publisher.loop_stop()
            publisher.disconnect()

    if rc["code"]:
        return rc["code"]

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

    # gw_status parity with ruuvi-go-gateway: retained online on (re)connect, LWT
    # offline if we vanish. Signature uses *rest to fit both paho 1.x and 2.x.
    status_topic = f"{args.site}/ruuvi/gw_status"
    client.will_set(status_topic, json.dumps({"state": "offline"}), qos=0, retain=True)

    def _on_connect(cl, *_rest):
        cl.publish(status_topic, json.dumps({"state": "online"}), qos=0, retain=True)

    client.on_connect = _on_connect
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    # connect_async + loop_start: retries in the background forever, so a broker
    # outage (at start or later) never kills the process — readings during the gap
    # are simply dropped, matching real-gateway behaviour.
    client.connect_async(args.mqtt_host, args.mqtt_port, keepalive=30)
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
        "--quiet",
        action="store_true",
        help="don't print every reading (for long unattended runs); logs tag "
        "discoveries and a 15-min heartbeat to stderr instead",
    )
    p.add_argument(
        "--once-seconds",
        type=float,
        default=8.0,
        help="how long to scan in --once mode (default: 8)",
    )
    # MQTT publishing — Phase 2+/M4, and Profile C service mode. CLI overrides env
    # (MQTT_HOST/MQTT_PORT/MQTT_USER/SITE), which a supervisor can inject wholesale.
    p.add_argument(
        "--mqtt-host",
        default=os.environ.get("MQTT_HOST"),
        help="Mosquitto host; enables MQTT publishing (env: MQTT_HOST)",
    )
    p.add_argument("--mqtt-port", type=int, default=int(os.environ.get("MQTT_PORT", "8883")))
    p.add_argument("--mqtt-user", default=os.environ.get("MQTT_USER"))
    p.add_argument("--mqtt-pass", help="or set $MQTT_PASS / MQTT_PASS= in .env beside the script")
    p.add_argument("--tls", action="store_true", help="use TLS for the MQTT connection")
    p.add_argument(
        "--site",
        default=os.environ.get("SITE", "test"),
        help="site name used in the topic prefix `<site>/ruuvi/<id>` "
        "(env: SITE; default: test)",
    )
    p.add_argument(
        "--stale-exit-seconds",
        type=float,
        default=0.0,
        help="exit(3) if NO BLE advertisements arrive for this long — lets a "
        "supervisor restart a scan that died under us (0 = disabled; ignored "
        "with --once)",
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
