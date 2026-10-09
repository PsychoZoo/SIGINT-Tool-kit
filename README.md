# SIGINT-Tool-kit

Run several signals-collection and analysis programs together with one command.
Each program runs in its own Docker container. They all share:

- **One central database** (PostgreSQL), where everything any program produces is stored.
- **One message bus** (MQTT), which programs use to send data, commands and alerts to each other in real time.
- **One API and dashboard**, where you can see what is running and watch data arrive live.

```
 ┌────────┐ ┌──────────┐ ┌───────────────┐ ┌───────────┐ ┌─────────────┐
 │ Kismet │ │ChirpStack│ │ SDR: ADS-B,   │ │ watchlist │ │ your module │   programs
 │        │ │ (LoRaWAN)│ │ AIS, rtl_433, │ │           │ │             │
 │        │ │          │ │ APRS          │ │           │ │             │
 └───┬────┘ └────┬─────┘ └──────┬────────┘ └─────┬─────┘ └──────┬──────┘
     │ publish / subscribe (MQTT topics sigint/...)           │
 ────┴───────────┴──────────────┴───────────────┴──────────────┴───  broker (Mosquitto)
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
| `./toolkit.sh up kismet lora adsb` | Also start any of the [integrations](#integrations): `kismet`, `lora`, `adsb`, `ais`, `ism`, `aprs`, `sdr` (all four SDR tools) or `all` |
| `./toolkit.sh status` / `logs [service]` | Show what is running, or follow its logs |
| `./toolkit.sh psql` | Open a SQL shell on the central database |
| `./toolkit.sh new-module <name>` | Create a new program from the template |
| `./toolkit.sh down` | Stop everything (data is kept) |
| `./toolkit.sh reset` | Stop everything and delete all data |

On the first run, `toolkit.sh` creates `.env` from `.env.example` with a random
database password and other secrets. Plain `docker compose ...` commands work too,
because `.env` sets `COMPOSE_FILE` so the integrations and your modules are always
included (for example `docker compose --profile kismet up -d`).

## What's included

| Service | Purpose |
|---|---|
| `db` | PostgreSQL 16, the central database (`db/init/01_schema.sql`) |
| `broker` | Mosquitto MQTT broker (port 1883, WebSockets on 9001) |
| `ingestor` | Saves every message on `sigint/+/data/#` to the `events` table and tracks modules |
| `api` | REST API, live WebSocket feed and the web dashboard |
| `simulator` *(profile `demo`)* | Generates fake data so you can try everything without hardware |
| `watchlist` *(module)* | Example of programs talking to each other: it raises alerts on matching data |

Plus the integrations below, each off until you enable its profile.

## Integrations

| Profile | Program | Hardware | Web UI | Stored as (module / kind) |
|---|---|---|---|---|
| `kismet` | [Kismet](https://www.kismetwireless.net/): Wi-Fi, Bluetooth and more | Wi-Fi adapter that supports monitor mode, Bluetooth adapter | `:2501` | `kismet` / `device`, `alert` |
| `lora` | [ChirpStack](https://www.chirpstack.io/) v4 LoRaWAN network server and gateway bridge | A LoRaWAN gateway (Semtech UDP packet forwarder) | `:8090` | `chirpstack` / `up`, `join`, `status`, ... |
| `adsb` | [readsb + tar1090](https://github.com/sdr-enthusiasts/docker-adsb-ultrafeeder): aircraft on 1090 MHz | RTL-SDR (+ 1090 MHz antenna) | `:8078` | `adsb` / `aircraft` |
| `ais` | [AIS-catcher](https://github.com/jvde-github/AIS-catcher): ships on 162 MHz | RTL-SDR (+ VHF marine antenna) | `:8100` | `ais` / `ship` |
| `ism` | [rtl_433](https://github.com/merbanan/rtl_433): weather stations, sensors, TPMS on 433/868/915 MHz | RTL-SDR | none | `rtl433` / `ism` |
| `aprs` | rtl_fm + [multimon-ng](https://github.com/EliasOenal/multimon-ng): amateur-radio APRS on 144.39/144.8 MHz | RTL-SDR (+ 2 m antenna) | none | `aprs` / `packet` |

`./toolkit.sh up` prints the web UI links for whatever it started. All settings are
in `.env`, which is documented inline.

### SDR dongles

Each SDR program needs **its own** RTL-SDR, because only one program can use a
dongle at a time. With more than one dongle plugged in, give each a unique serial
number once, then tell each program which one to use:

```bash
rtl_eeprom -d 0 -s ADSB      # unplug all but one dongle each time, then replug
rtl_eeprom -d 0 -s AIS
```

```ini
# .env
ADSB_SDR_SERIAL=ADSB
AIS_SDR_SERIAL=AIS
RTL433_SDR_SERIAL=ISM
APRS_SDR_SERIAL=APRS
```

On the host, blacklist the DVB-T kernel driver so it doesn't grab the dongles:
`echo 'blacklist dvb_usb_rtl28xxu' | sudo tee /etc/modprobe.d/blacklist-rtlsdr.conf`, then reboot.

### Kismet

Set `KISMET_SOURCES` in `.env` to the adapters Kismet should capture from, for
example `KISMET_SOURCES=wlan1 hci0`. Don't use the Wi-Fi adapter this machine
uses for its own network connection: Kismet puts it in monitor mode. Kismet runs
with host networking and privileged access so it can control the adapters, and
its own `.kismet` log files are kept in the `kismet-data` volume. Log in to the
web UI with `KISMET_USER` and the `KISMET_PASSWORD` that `.env` generated.

The `kismet` bridge polls Kismet every `KISMET_POLL_SECONDS` and stores every
device seen in that window (MAC, name, SSID, type, manufacturer, channel,
signal, location if Kismet has GPS) plus every Kismet alert.

### ChirpStack (LoRaWAN)

ChirpStack uses the shared Postgres server (its own `chirpstack` database) and
the shared MQTT broker, plus its own Redis.

1. Set `LORA_REGION` in `.env` to your gateways' region (`eu868`, `us915_0`, `us915_1`, `au915_0`, ...).
2. `./toolkit.sh up lora`, then open http://localhost:8090 and log in as `admin` / `admin`. Change the password.
3. Add your gateway, a device profile, an application and devices in the UI.
4. Point the gateway's packet forwarder at this machine's IP address, UDP port 1700.

Every uplink, join and status event is stored as `chirpstack` / `up`, `join`, ...
To send a downlink from any module or the API:

```bash
curl -X POST localhost:8080/api/modules/chirpstack/commands/downlink -H 'content-type: application/json' \
     -d '{"application_id": "<uuid>", "dev_eui": "0102030405060708", "f_port": 10, "data": "AQI="}'
```

If your database was created before the `lora` integration existed, run
`./toolkit.sh migrate` once to create the `chirpstack` database.

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
# The same works on real data: a MAC address from Kismet, an aircraft "hex"
# from ADS-B, a ship "mmsi" from AIS, or an APRS "source" callsign.
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

There are three ways to plug in an existing tool, all used by the integrations:

- **It can publish MQTT itself:** point it at the broker on
  `sigint/<name>/data/<kind>` (`rtl_433`, AIS-catcher).
- **It has an API or network output:** write a small bridge that reads from
  it and calls `mod.publish()` (`services/bridges/` for Kismet, ADS-B and ChirpStack).
- **It's a command-line tool:** run it from a Python module and parse its
  output (`services/aprs/aprs.py`).

To use real hardware, pass the device to the container in `modules/compose.yml`
(for example `devices: ["/dev/bus/usb:/dev/bus/usb"]` for SDR dongles, or
`network_mode: host` with `cap_add: [NET_ADMIN, NET_RAW]` for Wi-Fi monitor mode).

## Security notes

- The database, broker, API and integration web UIs listen on `127.0.0.1`
  only by default (ChirpStack's gateway port 1700/udp listens on all
  interfaces, set by `LORA_BIND_ADDRESS`, so your gateways can reach it). Before
  setting `BIND_ADDRESS=0.0.0.0`, add a Mosquitto `password_file`
  (`broker/mosquitto.conf`) and put the API behind authentication. The API has
  no login of its own.
- Only collect and decode signals you are legally permitted to receive in your
  jurisdiction.
