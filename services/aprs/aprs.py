"""APRS receiver: rtl_fm | multimon-ng, decoded packets published to the bus.

  sigint/aprs/data/packet   {"source", "destination", "path", "payload", "lat", "lon", ...}

APRS (amateur-radio position/telemetry packets) is on 144.390 MHz in North
America and 144.800 MHz in Europe; set APRS_FREQ to match your region.

Also an example of wrapping a command-line SDR tool as a toolkit module.
"""

import os
import re
import shlex
import signal
import subprocess
import threading

from sigint_common import Module

FREQ = os.environ.get("APRS_FREQ", "144.390M")
GAIN = os.environ.get("APRS_GAIN", "42")
PPM = os.environ.get("APRS_PPM", "0")
SERIAL = os.environ.get("APRS_SDR_SERIAL", "")

mod = Module("aprs", kind="sdr", meta={"freq": FREQ})

# multimon-ng -A prints e.g. "APRS: N0CALL-9>APDR16,WIDE1-1,qAR,W1XYZ:=4903.50N/07201.75W>comment"
LINE = re.compile(r"^APRS: (?P<source>[^>]+)>(?P<destination>[^,:]+)(?:,(?P<path>[^:]*))?:(?P<payload>.*)$")
# Uncompressed position: !, =, / or @ (the last two with a 7-char timestamp first)
POSITION = re.compile(r"^[!=/@](?:\d{6}[hz/])?(\d{2})(\d{2}\.\d{2})([NS]).(\d{3})(\d{2}\.\d{2})([EW])")


def parse(line: str) -> dict | None:
    m = LINE.match(line.strip())
    if not m:
        return None
    packet = m.groupdict()
    packet["path"] = packet["path"].split(",") if packet["path"] else []
    pos = POSITION.match(packet["payload"])
    if pos:
        lat = int(pos[1]) + float(pos[2]) / 60
        lon = int(pos[4]) + float(pos[5]) / 60
        packet["lat"] = round(-lat if pos[3] == "S" else lat, 5)
        packet["lon"] = round(-lon if pos[6] == "W" else lon, 5)
    return packet


def command() -> str:
    device = f"-d {shlex.quote(SERIAL)}" if SERIAL else ""
    return (
        f"rtl_fm {device} -f {shlex.quote(FREQ)} -s 22050 -g {shlex.quote(GAIN)} -p {shlex.quote(PPM)} - "
        "| multimon-ng -q -t raw -a AFSK1200 -A /dev/stdin"
    )


def stop_on_shutdown(proc: subprocess.Popen) -> None:
    """Kill the whole rtl_fm | multimon-ng pipeline when the module stops."""
    while proc.poll() is None:
        if mod.sleep(1):
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            return


def loop() -> None:
    while not mod.stopping:
        mod.log.info("starting: %s", command())
        proc = subprocess.Popen(command(), shell=True, stdout=subprocess.PIPE, text=True, start_new_session=True)
        threading.Thread(target=stop_on_shutdown, args=(proc,), daemon=True).start()
        for line in proc.stdout:
            packet = parse(line)
            if packet:
                mod.publish("packet", packet)
        proc.wait()
        if not mod.stopping:
            mod.log.warning("decoder exited with code %s, restarting in 10s", proc.returncode)
            mod.sleep(10)


if __name__ == "__main__":
    mod.run_forever(loop)
