"""Watchlist: an example of modules talking to each other.

It runs on the master, listens to every module's data from every node, checks
each message against a watchlist kept in its own database table, and publishes
an `alert` event when something matches. Other modules (or the dashboard) can
react to those alerts by subscribing to sigint/+/watchlist/data/alert; nodes
receive alerts over their link by default.

Commands (sigint/master/watchlist/cmd/...):
    add     {"value": "BAW123", "field": "callsign", "note": "..."}
    remove  {"value": "BAW123"}
    reload  {}
"""

from sigint_common import ALL_DATA, Message, Module

mod = Module("watchlist", kind="analysis")
entries: list[dict] = []


def setup_db() -> None:
    # Modules can own tables in the central database alongside the shared ones.
    mod.db().execute(
        """CREATE TABLE IF NOT EXISTS watchlist (
               id         serial PRIMARY KEY,
               value      text NOT NULL,
               field      text,  -- NULL matches the value in any field
               note       text,
               created_at timestamptz NOT NULL DEFAULT now(),
               UNIQUE NULLS NOT DISTINCT (value, field)
           )"""
    )


def reload() -> None:
    global entries
    rows = mod.db().execute("SELECT value, field, note FROM watchlist").fetchall()
    entries = [{"value": v.lower(), "field": f, "note": n} for v, f, n in rows]
    mod.log.info("loaded %d watchlist entries", len(entries))


def flatten(data, prefix: str = ""):
    if isinstance(data, dict):
        for key, value in data.items():
            yield from flatten(value, f"{prefix}{key}.")
    elif isinstance(data, list):
        for value in data:
            yield from flatten(value, prefix)
    else:
        yield prefix.rstrip(".").rsplit(".", 1)[-1], str(data).lower()


@mod.on(ALL_DATA)
def check(msg: Message) -> None:
    if msg.module == mod.name or not entries:  # never alert on alerts
        return
    for field, value in flatten(msg.data):
        for entry in entries:
            if entry["value"] == value and entry["field"] in (None, field):
                mod.publish("alert", {
                    "match": entry["value"], "field": field, "note": entry["note"],
                    "source_node": msg.node, "source_module": msg.module, "source_kind": msg.name,
                    "event": msg.data,
                })


@mod.command("add")
def add(msg: Message) -> None:
    mod.db().execute(
        "INSERT INTO watchlist (value, field, note) VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
        (str(msg.data["value"]), msg.data.get("field"), msg.data.get("note")),
    )
    reload()


@mod.command("remove")
def remove(msg: Message) -> None:
    mod.db().execute("DELETE FROM watchlist WHERE lower(value) = lower(%s)", (str(msg.data["value"]),))
    reload()


@mod.command("reload")
def on_reload(msg: Message) -> None:
    reload()


if __name__ == "__main__":
    setup_db()
    reload()
    mod.run_forever()
