"""ChirpStack bridge: republishes LoRaWAN device events into the toolkit.

ChirpStack's MQTT integration publishes on the shared broker at
  application/<application_id>/device/<dev_eui>/event/<event>
and this bridge republishes each one as
  sigint/chirpstack/data/<event>     (up, join, status, ack, txack, log, location, integration)
so the ingestor stores it and other modules can react to it.

Commands:
  sigint/chirpstack/cmd/downlink  {"application_id": "...", "dev_eui": "...",
                                   "f_port": 10, "data": "<base64>", "confirmed": false}
"""

import json

from sigint_common import Message, Module

mod = Module("chirpstack", kind="lora")


@mod.on("application/+/device/+/event/+")
def on_event(msg: Message) -> None:
    _, application_id, _, dev_eui, _, event = msg.topic.split("/")
    data = msg.data if isinstance(msg.data, dict) else {"value": msg.data}
    mod.publish(event, {"application_id": application_id, "dev_eui": dev_eui, **data})


@mod.command("downlink")
def downlink(msg: Message) -> None:
    d = msg.data
    topic = f"application/{d['application_id']}/device/{d['dev_eui']}/command/down"
    payload = {
        "devEui": d["dev_eui"],
        "confirmed": bool(d.get("confirmed", False)),
        "fPort": int(d.get("f_port", 1)),
        "data": d["data"],
    }
    mod.client.publish(topic, json.dumps(payload), qos=1)
    mod.log.info("queued downlink for %s", d["dev_eui"])


if __name__ == "__main__":
    mod.run_forever()
