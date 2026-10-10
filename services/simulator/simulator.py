"""Simulator: publishes fake ADS-B, Wi-Fi and 433 MHz sensor data so the whole
stack can be exercised without any radio hardware.

Commands:
    sigint/simulator/cmd/set_rate   {"rate": 2.5}   messages per second
    sigint/simulator/cmd/pause      {}
    sigint/simulator/cmd/resume     {}
"""

import os
import random

from sigint_common import Message, Module

mod = Module("simulator", kind="demo")
state = {"rate": float(os.environ.get("SIM_RATE", "1")), "paused": False}

AIRCRAFT = [
    {"icao": f"{random.randrange(0xFFFFFF):06x}", "callsign": cs,
     "lat": 51.47 + random.uniform(-1, 1), "lon": -0.45 + random.uniform(-1, 1),
     "altitude_ft": random.randrange(3000, 38000, 100), "heading": random.randrange(360)}
    for cs in ("BAW123", "EZY45K", "RYR8812", "DLH4AB", "UAL901", "KLM62C")
]
ACCESS_POINTS = [
    {"bssid": ":".join(f"{random.randrange(256):02x}" for _ in range(6)), "ssid": ssid,
     "channel": random.choice([1, 6, 11, 36, 44, 149])}
    for ssid in ("HomeNet", "CoffeeShop-Guest", "PRINTER-7F2A", "", "FreeWiFi", "IoT-Cam-03")
]
SENSORS = [
    {"model": "Acurite-Tower", "id": 1201}, {"model": "LaCrosse-TX141THBv2", "id": 77},
    {"model": "Oregon-THGR122N", "id": 14}, {"model": "Nexus-TH", "id": 203},
]


def adsb() -> tuple[str, dict]:
    ac = random.choice(AIRCRAFT)
    ac["lat"] += random.uniform(-0.02, 0.02)
    ac["lon"] += random.uniform(-0.02, 0.02)
    ac["altitude_ft"] = max(0, ac["altitude_ft"] + random.randrange(-200, 201, 100))
    return "adsb", {**ac, "lat": round(ac["lat"], 5), "lon": round(ac["lon"], 5),
                    "rssi": round(random.uniform(-30, -5), 1)}


def wifi() -> tuple[str, dict]:
    ap = random.choice(ACCESS_POINTS)
    return "wifi", {**ap, "rssi": random.randrange(-90, -30)}


def ism() -> tuple[str, dict]:
    s = random.choice(SENSORS)
    return "ism", {**s, "freq_mhz": 433.92, "temperature_C": round(random.uniform(-5, 30), 1),
                   "humidity": random.randrange(20, 95)}


@mod.command("set_rate")
def set_rate(msg: Message) -> None:
    state["rate"] = max(0.1, float(msg.data.get("rate", state["rate"])))
    mod.log.info("rate set to %.1f msg/s", state["rate"])


@mod.command("pause")
def pause(msg: Message) -> None:
    state["paused"] = True


@mod.command("resume")
def resume(msg: Message) -> None:
    state["paused"] = False


def loop() -> None:
    generators = [adsb, wifi, ism]
    while not mod.sleep(1 / state["rate"]):
        if not state["paused"]:
            mod.publish(*random.choice(generators)())


if __name__ == "__main__":
    mod.run_forever(loop)
