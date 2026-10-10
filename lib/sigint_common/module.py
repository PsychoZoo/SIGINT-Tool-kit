"""The Module class: everything a program needs to join the toolkit.

    from sigint_common import Module

    mod = Module("my-tool", kind="sensor")

    @mod.on("sigint/+/+/data/adsb")        # listen to other modules' data, on any node
    def handle(msg):
        print(msg.node, msg.module, msg.data)

    @mod.command("scan")                   # sigint/<this node>/my-tool/cmd/scan
    def scan(msg):
        mod.publish("result", {"found": 3})  # stored in the events table

    mod.run_forever()
"""

import json
import logging
import os
import signal
import socket
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

from . import db as dbmod
from .config import LOG_LEVEL, MQTT_HOST, MQTT_PASSWORD, MQTT_PORT, MQTT_USERNAME, NODE_NAME
from .topics import cmd_topic, data_topic, parse_topic, status_topic

log = logging.getLogger(__name__)


@dataclass
class Message:
    topic: str
    node: str  # device the publishing module runs on
    module: str  # module that published the message
    channel: str  # "data", "status" or "cmd"
    name: str  # data kind or command name
    data: Any  # decoded JSON, or {"raw": "..."} when the payload is not JSON
    payload: bytes
    ts: str | None = None  # ISO time the message was created, if the sender set it


Handler = Callable[[Message], None]


def _decode(payload: bytes) -> Any:
    try:
        return json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        return {"raw": payload.decode("utf-8", errors="replace")}


def _encode(data: Any) -> str:
    return json.dumps(data, default=str, separators=(",", ":"))


def _timestamped() -> Properties:
    """MQTT v5 properties carrying the creation time, so data buffered on a node
    while its link to the master is down is stored with the time it was seen."""
    props = Properties(PacketTypes.PUBLISH)
    props.UserProperty = ("ts", datetime.now(timezone.utc).isoformat())
    return props


class Module:
    def __init__(
        self,
        name: str | None = None,
        kind: str = "generic",
        meta: dict | None = None,
        heartbeat: float = 30.0,
        persistent_session: bool = False,
    ):
        """persistent_session: the broker keeps this module's subscriptions and
        queues its messages while it is disconnected (e.g. restarting), so nothing
        is missed. Only one instance per node may then run at a time."""
        logging.basicConfig(
            level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
        )
        self.name = name or os.environ["MODULE_NAME"]
        self.node = NODE_NAME
        self.kind = kind
        self.meta = {"host": socket.gethostname(), "node": NODE_NAME, **(meta or {})}
        self.heartbeat = heartbeat
        self.persistent_session = persistent_session
        self.log = logging.getLogger(self.name)

        self._handlers: list[tuple[str, Handler]] = []
        self._stop = threading.Event()
        self._stopped = False
        self._db = None
        self._db_lock = threading.Lock()

        self.client = mqtt.Client(
            CallbackAPIVersion.VERSION2,
            client_id=f"{NODE_NAME}-{self.name}"
            if persistent_session
            else f"{NODE_NAME}-{self.name}-{uuid.uuid4().hex[:8]}",
            protocol=mqtt.MQTTv5,
        )
        if MQTT_USERNAME:
            self.client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
        self.client.will_set(
            status_topic(self.name), self._status("offline"), qos=1, retain=True
        )
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)

    # -- messaging ---------------------------------------------------------

    def publish(self, kind: str, data: Any, retain: bool = False, qos: int = 1) -> None:
        """Publish data on sigint/<node>/<this module>/data/<kind>; the ingestor stores it."""
        self.client.publish(
            data_topic(self.name, kind), _encode(data), qos=qos, retain=retain, properties=_timestamped()
        )

    def send_command(self, module: str, command: str, data: Any = None, node: str | None = None) -> None:
        """Send a command to a module on this node, or on another node."""
        self.client.publish(cmd_topic(module, command, node or NODE_NAME), _encode(data or {}), qos=1)

    def subscribe(self, pattern: str, handler: Handler) -> None:
        self._handlers.append((pattern, handler))
        if self.client.is_connected():
            self.client.subscribe(pattern, qos=1)

    def on(self, pattern: str) -> Callable[[Handler], Handler]:
        """Decorator form of subscribe()."""

        def register(handler: Handler) -> Handler:
            self.subscribe(pattern, handler)
            return handler

        return register

    def command(self, command: str = "#") -> Callable[[Handler], Handler]:
        """Decorator: handle commands sent to this module on this node."""
        return self.on(cmd_topic(self.name, command))

    # -- database ----------------------------------------------------------

    def db(self):
        """Shared autocommit connection to the central database (reconnects if needed)."""
        with self._db_lock:
            if self._db is None or self._db.closed or self._db.broken:
                self._db = dbmod.connect()
            return self._db

    def kv_get(self, key: str, default=None, namespace: str | None = None):
        return dbmod.kv_get(self.db(), namespace or self.name, key, default)

    def kv_set(self, key: str, value, namespace: str | None = None) -> None:
        dbmod.kv_set(self.db(), namespace or self.name, key, value)

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        """Connect to the broker and start the network loop in the background."""
        if self.persistent_session:
            props = Properties(PacketTypes.CONNECT)
            props.SessionExpiryInterval = 7 * 24 * 3600
            self.client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30, clean_start=False, properties=props)
        else:
            self.client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
        self.client.loop_start()
        threading.Thread(target=self._heartbeat_loop, daemon=True).start()
        self.log.info("started, broker %s:%s", MQTT_HOST, MQTT_PORT)

    def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        self._stop.set()
        info = self.client.publish(
            status_topic(self.name), self._status("offline"), qos=1, retain=True
        )
        try:
            info.wait_for_publish(timeout=2)
        except (RuntimeError, ValueError):
            pass
        self.client.disconnect()
        self.client.loop_stop()
        if self._db is not None:
            self._db.close()
        self.log.info("stopped")

    @property
    def stopping(self) -> bool:
        return self._stop.is_set()

    def sleep(self, seconds: float) -> bool:
        """Sleep, returning early (True) if the module is shutting down."""
        return self._stop.wait(seconds)

    def run_forever(self, loop: Callable[[], None] | None = None) -> None:
        """Start, then block until SIGINT/SIGTERM. `loop` runs in the main thread if given."""
        signal.signal(signal.SIGTERM, lambda *_: self._stop.set())
        signal.signal(signal.SIGINT, lambda *_: self._stop.set())
        self.start()
        try:
            if loop is not None:
                loop()
            self._stop.wait()
        finally:
            self.stop()

    # -- internals ---------------------------------------------------------

    def _status(self, status: str) -> str:
        return _encode({"status": status, "kind": self.kind, "meta": self.meta, "ts": time.time()})

    def _heartbeat_loop(self) -> None:
        while not self._stop.wait(self.heartbeat):
            if self.client.is_connected():
                self.client.publish(
                    status_topic(self.name), self._status("online"), qos=1, retain=True
                )

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            self.log.error("broker refused connection: %s", reason_code)
            return
        self.log.info("connected to broker")
        for pattern in {p for p, _ in self._handlers}:
            client.subscribe(pattern, qos=1)
        client.publish(status_topic(self.name), self._status("online"), qos=1, retain=True)

    def _on_message(self, client, userdata, msg) -> None:
        parsed = parse_topic(msg.topic)
        user_props = dict(getattr(msg.properties, "UserProperty", None) or [])
        message = Message(
            topic=msg.topic,
            node=parsed.node if parsed else "",
            module=parsed.module if parsed else "",
            channel=parsed.channel if parsed else "",
            name=parsed.name if parsed else "",
            data=_decode(msg.payload),
            payload=msg.payload,
            ts=user_props.get("ts"),
        )
        for pattern, handler in self._handlers:
            if mqtt.topic_matches_sub(pattern, msg.topic):
                try:
                    handler(message)
                except Exception:
                    self.log.exception("handler for %s failed on %s", pattern, msg.topic)
