# SIGINT-Tool-kit

Run several signals-collection and analysis programs together with one command.
Each program runs in its own Docker container. They all share:

- **One central database** (PostgreSQL), where everything any program produces is stored.
- **One message bus** (MQTT), which programs use to send data, commands and alerts to each other in real time.
- **One API and dashboard**, where you can see what is running and watch data arrive live.

```
 ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐
 │ rtl_433  │  │simulator │  │ watchlist │  │ your module  │   programs
 └────┬─────┘  └────┬─────┘  └─────┬─────┘  └──────┬───────┘
      │ publish / subscribe (MQTT topics sigint/...) │
 ─────┴─────────────┴──────────────┴───────────────┴───────  broker (Mosquitto)
                    │                         │
              ┌─────┴─────┐            ┌──────┴──────┐
              │ ingestor  │──writes──▶ │  PostgreSQL │◀── SQL from any module
              └───────────┘            └──────┬──────┘
                                              │ LISTEN/NOTIFY
                                       ┌──────┴──────┐
                                       │ API + web   │  http://localhost:8080
                                       └─────────────┘
```

## Quick start

You need Docker with the Compose plugin.

```bash
./toolkit.sh up demo     # start everything plus a simulator that generates fake data
```

Open <http://localhost:8080> for the dashboard and <http://localhost:8080/docs> for the API.

| Command | What it does |
|---|---|
| `./toolkit.sh up` | Start the core stack and your modules |
| `./toolkit.sh up demo` | Also start the simulator (fake ADS-B, Wi-Fi and 433 MHz data) |
| `./toolkit.sh up sdr` | Also start `rtl_433` on a USB RTL-SDR dongle |
| `./toolkit.sh status` / `logs [service]` | Show what is running, or follow its logs |
| `./toolkit.sh psql` | Open a SQL shell on the central database |
| `./toolkit.sh new-module <name>` | Create a new program from the template |
| `./toolkit.sh down` | Stop everything (data is kept) |
| `./toolkit.sh reset` | Stop everything and delete all data |

On the first run, `toolkit.sh` creates `.env` from `.env.example` with a random
database password. Plain `docker compose ...` commands work too, because `.env`
sets `COMPOSE_FILE` so your modules are always included.

## What's included

| Service | Purpose |
|---|---|
| `db` | PostgreSQL 16, the central database (`db/init/01_schema.sql`) |
| `broker` | Mosquitto MQTT broker (port 1883, WebSockets on 9001) |
| `ingestor` | Saves every message on `sigint/+/data/#` to the `events` table and tracks modules |
| `api` | REST API, live WebSocket feed and the web dashboard |
| `simulator` *(profile `demo`)* | Generates fake data so you can try everything without hardware |
| `rtl433` *(profile `sdr`)* | [rtl_433](https://github.com/merbanan/rtl_433) decoder for 433/868/915 MHz devices |
| `watchlist` *(module)* | Example of programs talking to each other: it raises alerts on matching data |

## How programs talk to each other

Every program follows the same MQTT topic layout:

| Topic | Meaning |
|---|---|
| `sigint/<module>/data/<kind>` | Data a module produced. The ingestor **stores** it in the database. |
| `sigint/<module>/cmd/<command>` | A command sent **to** a module |
| `sigint/<module>/status` | Retained `online`/`offline` status, sent automatically |

Payloads are JSON. So any program, in any language, can join by publishing JSON
to `sigint/<its name>/data/<kind>`. `rtl_433` does this with no extra code.

For example, with the demo running:

```bash
# Add a watchlist entry. The watchlist module stores it in its own table.
curl -X POST localhost:8080/api/modules/watchlist/commands/add \
     -H 'content-type: application/json' -d '{"value": "BAW123", "field": "callsign"}'

# The simulator publishes BAW123 positions, watchlist matches them and publishes
# alerts, the ingestor stores those, and they appear in red on the dashboard.
curl 'localhost:8080/api/events?module=watchlist&kind=alert&limit=5'

# Control another module
curl -X POST localhost:8080/api/modules/simulator/commands/set_rate -d '{"rate": 5}' -H 'content-type: application/json'
```

## The central database

| Table | Contents |
|---|---|
| `events` | Every data message: `id, ts, module, kind, topic, data (jsonb)` |
| `modules` | Every program seen: status, kind, metadata, first and last seen |
| `kv` | Shared key/value store for config and state (`namespace, key, value`) |

Modules can also create their own tables, as `watchlist` does. Each insert into
`events` fires a `NOTIFY sigint_events`, so programs can react to new data from
SQL as well as from MQTT.

Example queries (`./toolkit.sh psql`):

```sql
SELECT module, kind, count(*) FROM events GROUP BY 1, 2;
SELECT ts, data->>'callsign', data->>'altitude_ft' FROM events
 WHERE kind = 'adsb' AND data @> '{"callsign": "BAW123"}' ORDER BY ts DESC LIMIT 20;
```

## API

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Database and bus status |
| `GET /api/modules` | All modules and their status |
| `GET /api/events?module=&kind=&since=&after_id=&contains=&limit=` | Query stored events (`contains` is a JSON filter) |
| `GET /api/events/{id}` | One event |
| `GET /api/stats` | Event counts per module and kind |
| `POST /api/publish` | Publish `{module, kind, data}` onto the bus |
| `POST /api/modules/{name}/commands/{command}` | Send a command to a module |
| `GET /api/kv/{namespace}` / `PUT /api/kv/{namespace}/{key}` | Shared key/value store |
| `WS /api/live` | Stream of new events as they are stored |

## Adding your own program

```bash
./toolkit.sh new-module wifi-scanner
# edit modules/wifi-scanner/main.py, and add any packages to requirements.txt
./toolkit.sh up
```

The template uses the shared Python library in `lib/sigint_common`:

```python
from sigint_common import Module

mod = Module("wifi-scanner", kind="sensor")

@mod.on("sigint/+/data/adsb")         # listen to another module's data
def on_adsb(msg):
    print(msg.module, msg.data["callsign"])

@mod.command("scan")                  # POST /api/modules/wifi-scanner/commands/scan
def scan(msg):
    mod.publish("ap", {"bssid": "...", "ssid": "..."})   # stored in the events table

def loop():
    while not mod.sleep(5):
        ...                             # your main work
        mod.kv_set("last_scan", {"ok": True})            # shared state in the database
        rows = mod.db().execute("SELECT count(*) FROM events").fetchone()

mod.run_forever(loop)
```

To wrap an existing tool that isn't written in Python, give it its own
Dockerfile (see `services/rtl433/`) and point its output at the broker on
`sigint/<name>/data/<kind>`, or pipe its output through a small Python module.

To use real hardware, pass the device to the container in `modules/compose.yml`
(for example `devices: ["/dev/bus/usb:/dev/bus/usb"]` for SDR dongles, or
`network_mode: host` with `cap_add: [NET_ADMIN, NET_RAW]` for Wi-Fi monitor mode).

## Security notes

- The database, broker and API listen on `127.0.0.1` only by default. Before
  setting `BIND_ADDRESS=0.0.0.0`, add a Mosquitto `password_file`
  (`broker/mosquitto.conf`) and put the API behind authentication. The API has
  no login of its own.
- Only collect and decode signals you are legally permitted to receive in your
  jurisdiction.
