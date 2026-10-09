"""Kismet bridge: polls Kismet's REST API and publishes what it sees.

  sigint/kismet/data/device   a device (Wi-Fi AP/client, Bluetooth, ...) seen since the last poll
  sigint/kismet/data/alert    a Kismet alert (deauth floods, spoofed APs, ...)

https://www.kismetwireless.net/docs/devel/webui_rest/
"""

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from sigint_common import Module

KISMET_URL = os.environ.get("KISMET_URL", "http://127.0.0.1:2501").rstrip("/")
POLL_SECONDS = float(os.environ.get("KISMET_POLL_SECONDS", "30"))
AUTH = "Basic " + base64.b64encode(
    f"{os.environ['KISMET_USER']}:{os.environ['KISMET_PASSWORD']}".encode()
).decode()

DEVICE_FIELDS = [
    ["kismet.device.base.key", "key"],
    ["kismet.device.base.macaddr", "mac"],
    ["kismet.device.base.commonname", "name"],
    ["kismet.device.base.type", "type"],
    ["kismet.device.base.phyname", "phy"],
    ["kismet.device.base.manuf", "manuf"],
    ["kismet.device.base.crypt", "crypt"],
    ["kismet.device.base.channel", "channel"],
    ["kismet.device.base.frequency", "frequency_khz"],
    ["kismet.device.base.first_time", "first_time"],
    ["kismet.device.base.last_time", "last_time"],
    ["kismet.device.base.packets.total", "packets"],
    ["kismet.device.base.signal/kismet.common.signal.last_signal", "signal_dbm"],
    ["kismet.device.base.location/kismet.common.location.last/kismet.common.location.geopoint", "lon_lat"],
    ["dot11.device/dot11.device.last_beaconed_ssid_record/dot11.advertisedssid.ssid", "ssid"],
]

mod = Module("kismet", kind="wireless", meta={"url": KISMET_URL})


def kismet(path: str, body: dict | None = None):
    data = urllib.parse.urlencode({"json": json.dumps(body)}).encode() if body else None
    req = urllib.request.Request(KISMET_URL + path, data=data, headers={"Authorization": AUTH})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def strip_prefix(alert: dict) -> dict:
    return {k.removeprefix("kismet.alert."): v for k, v in alert.items()}


def loop() -> None:
    device_since = -max(1, int(POLL_SECONDS))  # negative = relative to now
    alert_since = int(time.time())
    while not mod.stopping:
        try:
            started = int(time.time())
            devices = kismet(f"/devices/last-time/{device_since}/devices.json", {"fields": DEVICE_FIELDS})
            for device in devices:
                mod.publish("device", device)
            device_since = started - 1  # small overlap so nothing falls between polls

            alerts = kismet(f"/alerts/wrapped/last-time/{alert_since}/alerts.json")
            for alert in alerts.get("kismet.alert.list", []):
                mod.publish("alert", strip_prefix(alert))
            alert_since = alerts.get("kismet.alert.timestamp", alert_since)

            mod.log.info("published %d devices, %d alerts", len(devices), len(alerts.get("kismet.alert.list", [])))
        except (urllib.error.URLError, OSError, ValueError) as exc:
            mod.log.warning("Kismet not reachable at %s (%s)", KISMET_URL, exc)
        mod.sleep(POLL_SECONDS)


if __name__ == "__main__":
    mod.run_forever(loop)
