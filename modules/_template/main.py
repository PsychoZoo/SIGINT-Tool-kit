"""__NAME__: describe what this program does.

Created from modules/_template by `./toolkit.sh new-module __NAME__`.
"""

from sigint_common import Message, Module

mod = Module("__NAME__", kind="generic")


# React to data from other modules (wildcards: + = one level, # = the rest).
@mod.on("sigint/+/data/#")
def on_data(msg: Message) -> None:
    mod.log.debug("%s/%s: %s", msg.module, msg.name, msg.data)


# Handle commands sent to this module: POST /api/modules/__NAME__/commands/ping
@mod.command("ping")
def ping(msg: Message) -> None:
    mod.publish("pong", {"echo": msg.data})


def loop() -> None:
    """Main work loop. Publish whatever this program produces; it is stored in
    the central `events` table automatically."""
    while not mod.sleep(10):
        mod.publish("heartbeat", {"ok": True})
        # mod.db() gives a connection to the central database if you need SQL,
        # mod.kv_get()/kv_set() store small bits of config or state.


if __name__ == "__main__":
    mod.run_forever(loop)
