"""MQTT topic conventions shared by every module.

    sigint/<module>/status            retained online/offline status
    sigint/<module>/data/<kind>       data the module produced (stored in the DB)
    sigint/<module>/cmd/<command>     commands sent *to* the module
"""

from dataclasses import dataclass

from .config import TOPIC_ROOT

ALL_DATA = f"{TOPIC_ROOT}/+/data/#"
ALL_STATUS = f"{TOPIC_ROOT}/+/status"


def data_topic(module: str, kind: str) -> str:
    return f"{TOPIC_ROOT}/{module}/data/{kind}"


def status_topic(module: str) -> str:
    return f"{TOPIC_ROOT}/{module}/status"


def cmd_topic(module: str, command: str) -> str:
    return f"{TOPIC_ROOT}/{module}/cmd/{command}"


@dataclass
class ParsedTopic:
    module: str
    channel: str  # "data", "status" or "cmd"
    name: str  # data kind or command name ("" for status)


def parse_topic(topic: str) -> ParsedTopic | None:
    parts = topic.split("/")
    if len(parts) < 3 or parts[0] != TOPIC_ROOT:
        return None
    return ParsedTopic(module=parts[1], channel=parts[2], name="/".join(parts[3:]))
