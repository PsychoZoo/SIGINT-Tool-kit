"""__NAME__: describe what this program does.

Created from modules/_template by `./toolkit.sh new-module __NAME__`.
"""

from sigint_common import Message, Module

mod = Module("__NAME__", kind="generic")


# React to data from other modules: sigint/<node>/<module>/data/<kind>
# (wildcards: + = one level, # = the rest). On a node, only topics the node
# imports over its link arrive from other nodes (NODE_IMPORT_TOPICS in .env).
@mod.on("sigint/+/+/data/#")
def on_data(msg: Message) -> None:
    mod.log.debug("%s/%s/%s: %s", msg.node, msg.module, msg.name, msg.data)


# Handle commands sent to this module:
#   POST /api/nodes/<this node>/modules/__NAME__/commands/ping
@mod.command("ping")
def ping(msg: Message) -> None:
    mod.publish("pong", {"echo": msg.data})


def loop() -> None:
    """Main work loop. Publish whatever this program produces; it is stored in
    the central `events` table automatically."""
    while not mod.sleep(10):
        mod.publish("heartbeat", {"ok": True})
        # On the master, mod.db() gives a connection to the central database and
        # mod.kv_get()/kv_set() store small bits of config or state. Nodes have no
        # database: there, everything goes over the bus.


if __name__ == "__main__":
    mod.run_forever(loop)
