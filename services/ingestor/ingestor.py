"""Ingestor: stores everything published on the bus in the central database.

  sigint/<module>/data/<kind>  -> row in `events`, and `modules.last_seen` bumped
  sigint/<module>/status       -> `modules` row upserted (status, kind, meta)
"""

import os
import threading

import psycopg
from psycopg.types.json import Jsonb

from sigint_common import ALL_DATA, ALL_STATUS, Message, Module

RETENTION_DAYS = float(os.environ.get("EVENT_RETENTION_DAYS", "0"))

mod = Module("ingestor", kind="core")
write_lock = threading.Lock()


def execute(sql: str, params: tuple) -> None:
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
               INSERT INTO modules (name, status) VALUES (%(module)s, 'online')
               ON CONFLICT (name) DO UPDATE SET last_seen = now()
           )
           INSERT INTO events (module, kind, topic, data)
           VALUES (%(module)s, %(kind)s, %(topic)s, %(data)s)""",
        {"module": msg.module, "kind": msg.name or "default", "topic": msg.topic, "data": Jsonb(data)},
    )


@mod.on(ALL_STATUS)
def store_status(msg: Message) -> None:
    if not msg.payload:  # retained message cleared
        return
    info = msg.data if isinstance(msg.data, dict) else {}
    execute(
        """INSERT INTO modules (name, kind, status, meta)
           VALUES (%(name)s, %(kind)s, %(status)s, %(meta)s)
           ON CONFLICT (name) DO UPDATE SET
               kind = COALESCE(EXCLUDED.kind, modules.kind),
               status = EXCLUDED.status,
               meta = EXCLUDED.meta,
               last_seen = now()""",
        {
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
    if RETENTION_DAYS > 0:
        threading.Thread(target=prune_loop, daemon=True).start()
    mod.run_forever()
