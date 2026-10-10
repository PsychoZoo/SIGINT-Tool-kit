"""MQTT topic conventions shared by every module, on every node.

    sigint/<node>/<module>/status            retained online/offline status
    sigint/<node>/<module>/data/<kind>       data the module produced (stored in the DB)
    sigint/<node>/<module>/cmd/<command>     commands sent *to* the module
    sigint/<node>/node/status                "1"/"0": the node's link to the master

<node> is the device the module runs on (NODE_NAME), so two nodes can run the
same program without their data getting mixed up.
"""

from dataclasses import dataclass

from .config import NODE_NAME, TOPIC_ROOT

ALL_DATA = f"{TOPIC_ROOT}/+/+/data/#"
ALL_STATUS = f"{TOPIC_ROOT}/+/+/status"


def data_topic(module: str, kind: str, node: str = NODE_NAME) -> str:
    return f"{TOPIC_ROOT}/{node}/{module}/data/{kind}"


def status_topic(module: str, node: str = NODE_NAME) -> str:
    return f"{TOPIC_ROOT}/{node}/{module}/status"


def cmd_topic(module: str, command: str, node: str = NODE_NAME) -> str:
    return f"{TOPIC_ROOT}/{node}/{module}/cmd/{command}"


@dataclass
class ParsedTopic:
    node: str
    module: str
    channel: str  # "data", "status" or "cmd"
    name: str  # data kind or command name ("" for status)


def parse_topic(topic: str) -> ParsedTopic | None:
    parts = topic.split("/")
    if len(parts) < 4 or parts[0] != TOPIC_ROOT:
        return None
    return ParsedTopic(node=parts[1], module=parts[2], channel=parts[3], name="/".join(parts[4:]))
