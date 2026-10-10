"""ADS-B bridge: reads readsb's JSON position stream and publishes each update.

  sigint/adsb/data/aircraft   one aircraft position/state update

readsb (inside the ultrafeeder container) writes one JSON object per line on
TCP port 30047; field reference:
https://github.com/wiedehopf/readsb/blob/dev/README-json.md
"""

import json
import os
import socket

from sigint_common import Module

HOST = os.environ.get("ADSB_HOST", "adsb")
PORT = int(os.environ.get("ADSB_JSON_PORT", "30047"))

mod = Module("adsb", kind="sdr", meta={"source": f"{HOST}:{PORT}"})


def handle_line(line: bytes) -> None:
    try:
        aircraft = json.loads(line)
    except ValueError:
        return
    if isinstance(aircraft.get("flight"), str):
        aircraft["flight"] = aircraft["flight"].strip()
    mod.publish("aircraft", aircraft, qos=0)


def stream() -> None:
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        mod.log.info("connected to readsb at %s:%s", HOST, PORT)
        sock.settimeout(1)  # wake up regularly so shutdown is prompt
        buffer = b""
        while not mod.stopping:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError("readsb closed the connection")
            buffer += chunk
            *lines, buffer = buffer.split(b"\n")
            for line in lines:
                if line.strip():
                    handle_line(line)


def loop() -> None:
    while not mod.stopping:
        try:
            stream()
        except OSError as exc:
            mod.log.warning("readsb not reachable at %s:%s (%s), retrying", HOST, PORT, exc)
        mod.sleep(5)


if __name__ == "__main__":
    mod.run_forever(loop)
