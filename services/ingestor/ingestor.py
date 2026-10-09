"""Ingestor (master only): stores everything published on the bus, from every
node, in the central database.

  sigint/<node>/<module>/data/<kind>  -> row in `events`, and the module's `last_seen` bumped
  sigint/<node>/<module>/status       -> `modules` row upserted (status, kind, meta)
  sigint/<node>/node/status           -> the node's link to the master ("1"/"0"); when a
                                         link drops, all of that node's modules go offline
"""

import os
import threading

import psycopg
from psycopg.types.json import Jsonb

from sigint_common import ALL_DATA, ALL_STATUS, Message, Module

RETENTION_DAYS = float(os.environ.get("EVENT_RETENTION_DAYS", "0"))

mod = Module("ingestor", kind="core", persistent_session=True)
write_lock = threading.Lock()


def execute(sql: str, params) -> None:
    # One retry covers a dropped connection (e.g. the database restarted).
    with write_lock:
        try:
            mod.db().execute(sql, params)
        except psycopg.OperationalError:
            mod.log.warning("database connection lost, reconnecting")
            mod.db().execute(sql, params)


@mod.on(ALL_DATA)
def store_event(msg: Message) -> None:
    data = msg.data if isinstance(msg.data, (dict, list)) else {"value": msg.data}
    execute(
        """WITH m AS (
               INSERT INTO modules (node, name, status) VALUES (%(node)s, %(module)s, 'online')
               ON CONFLICT (node, name) DO UPDATE SET last_seen = now()
           )
           INSERT INTO events (ts, node, module, kind, topic, data)
           VALUES (COALESCE(%(ts)s::timestamptz, now()), %(node)s, %(module)s, %(kind)s, %(topic)s, %(data)s)""",
        {
            "ts": msg.ts,
            "node": msg.node,
            "module": msg.module,
            "kind": msg.name or "default",
            "topic": msg.topic,
            "data": Jsonb(data),
        },
    )


def store_link_status(node: str, online: bool) -> None:
    status = "online" if online else "offline"
    execute(
        """INSERT INTO modules (node, name, kind, status) VALUES (%(node)s, 'node', 'node', %(status)s)
           ON CONFLICT (node, name) DO UPDATE SET status = EXCLUDED.status, last_seen = now()""",
        {"node": node, "status": status},
    )
    if not online:
        # The node's modules can't report their own status while it is cut off.
        execute("UPDATE modules SET status = 'offline' WHERE node = %s AND name <> 'node'", (node,))
    mod.log.info("node %s is %s", node, status)


@mod.on(ALL_STATUS)
def store_status(msg: Message) -> None:
    if not msg.payload:  # retained message cleared
        return
    if msg.module == "node":
        store_link_status(msg.node, msg.payload.strip() == b"1")
        return
    info = msg.data if isinstance(msg.data, dict) else {}
    execute(
        """INSERT INTO modules (node, name, kind, status, meta)
           VALUES (%(node)s, %(name)s, %(kind)s, %(status)s, %(meta)s)
           ON CONFLICT (node, name) DO UPDATE SET
               kind = COALESCE(EXCLUDED.kind, modules.kind),
               status = EXCLUDED.status,
               meta = EXCLUDED.meta,
               last_seen = now()""",
        {
            "node": msg.node,
            "name": msg.module,
            "kind": info.get("kind"),
            "status": str(info.get("status", "unknown")),
            "meta": Jsonb(info.get("meta") or {}),
        },
    )


def prune_loop() -> None:
    while not mod.sleep(3600):
        execute("DELETE FROM events WHERE ts < now() - make_interval(secs => %s)", (RETENTION_DAYS * 86400,))
        mod.log.info("pruned events older than %s days", RETENTION_DAYS)


if __name__ == "__main__":
    mod.db()  # wait for the database before taking messages off the bus
    store_link_status(mod.node, True)  # the master is always linked to itself
    if RETENTION_DAYS > 0:
        threading.Thread(target=prune_loop, daemon=True).start()
    mod.run_forever()
