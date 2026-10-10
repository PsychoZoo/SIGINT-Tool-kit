# SIGINT-Tool-kit

Run several signals-collection and analysis programs together with one command.
Each program runs in its own Docker container. They all share:

- **One central database** (PostgreSQL), where everything any program produces is stored.
- **One message bus** (MQTT), which programs use to send data, commands and alerts to each other in real time.
- **One API and dashboard**, where you can see what is running and watch data arrive live.

It can run on one machine, or across [many devices](#multiple-devices-master-and-nodes):
one **master** holds the database and dashboard, and any number of **nodes**
(for example Raspberry Pis with radios) send everything they collect to it, over
your local network or through Cloudflare.

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

> **Step-by-step guide:** [docs/GUIDE.md](docs/GUIDE.md): set up a master, flash
> nodes, reach the dashboard from anywhere, troubleshooting. The same guide is
> on every master at `http://localhost:8080/guide`, with no internet needed.

## Quick start

The fastest way to set up a master is the guided setup. It installs Docker if
needed, asks a few questions, starts everything, and then offers to
[flash ready-to-run nodes](#flash-ready-to-run-nodes):

```bash
./toolkit.sh setup
```

Or, if you already have Docker with the Compose plugin:

```bash
./toolkit.sh up demo     # start everything plus a simulator that generates fake data
```

Open <http://localhost:8080> for the dashboard, <http://localhost:8080/guide> for the
guide and <http://localhost:8080/docs> for the API. All three work without internet.

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
| `ingestor` | Saves every message on `sigint/+/+/data/#`, from every node, to the `events` table and tracks modules and nodes |
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
ChirpStack runs on the master (it needs the database); gateways anywhere can
point at it. To send a downlink from any module or the API:

```bash
curl -X POST localhost:8080/api/modules/chirpstack/commands/downlink -H 'content-type: application/json' \
     -d '{"application_id": "<uuid>", "dev_eui": "0102030405060708", "f_port": 10, "data": "AQI="}'
```

If your database was created before the `lora` integration existed, run
`./toolkit.sh migrate` once to create the `chirpstack` database.

## Multiple devices (master and nodes)

Every device runs this same repository in one of two roles:

| Role | Runs | Stores data |
|---|---|---|
| **master** (one) | Database, ingestor, API and dashboard, broker, plus any programs | Everything from every device |
| **node** (any number) | Broker that links to the master, plus any programs (Kismet, SDR tools, your modules...) | Nothing permanently. It buffers on disk while the master is unreachable. |

```
   node "roof-pi"              master                       node "van"
 ┌────────────────┐     ┌──────────────────────┐     ┌────────────────┐
 │ adsb ais kismet│     │ database   dashboard │     │ kismet aprs    │
 │     broker ────┼────▶│ broker (port 1884)   │◀────┼──── broker     │
 └────────────────┘     │ ingestor  watchlist  │     └────────────────┘
          local network └──────────────────────┘ Cloudflare Tunnel
```

- **Data** from every node goes to the master and is stored with the node's name.
- **Commands** go from the master (or from any node) to a module on a specific node.
- **Alerts** from the watchlist go back to all nodes, and nodes can receive
  any other topics they want (`NODE_IMPORT_TOPICS`).
- **If the link drops**, the node keeps collecting and queues everything on
  disk. When the link returns, the data is delivered and stored with the time it
  was collected, not the time it arrived. The dashboard shows each node as online
  or offline.
- **Each node has its own login** and can only publish data under its own
  name. A node that is lost or stolen can be locked out with `remove-node`.

### Setting it up

On the **master** (the device that keeps the data):

```bash
./toolkit.sh up            # plus any programs it should run itself, e.g. ./toolkit.sh up adsb
./toolkit.sh add-node roof-pi
```

`add-node` creates a login for the node and prints the exact command to run on it:

```bash
# on the new device, after cloning this repository
./toolkit.sh join --name roof-pi --master 192.168.1.10:1884 --password <printed password>
./toolkit.sh up adsb ais   # whatever programs this node should run
```

Then:
- `./toolkit.sh nodes` on the master lists the nodes and whether they're connected.
- `./toolkit.sh role` shows a device's role.
- `./toolkit.sh remove-node roof-pi` revokes a node's login.

Nodes connect to the master on port **1884** (`NODE_PORT`). The master listens on
it on all network interfaces (`NODE_LISTEN_ADDRESS`), so open it in the
master's firewall for your LAN if it filters Docker's published ports (ufw and
firewalld usually don't: Docker opens them itself). To accept nodes on one
address only, set `NODE_LISTEN_ADDRESS` to it. Nothing on a node needs to be reachable.

### Flash ready-to-run nodes

Instead of setting nodes up by hand, the master can write a complete,
preconfigured system to an SD card or USB drive. Put it in the device, power it
on, and it joins the master by itself: nobody has to log in.

```bash
./toolkit.sh flash-node
```

It asks for the node's name, its programs, your Wi-Fi details and an SSH key
(answers are remembered for next time), creates the node's login, builds the
system and writes it to the card you pick. At the end it offers to flash another
node with the same settings, so two Raspberry Pis take two cards and a few minutes.

| Device | `--target` | What the card holds | What happens |
|---|---|---|---|
| Raspberry Pi 3, 4, 5, Zero 2 W | `pi` | Official Raspberry Pi OS Lite (64-bit) + cloud-init settings | Boots, connects (Wi-Fi or Ethernet), installs Docker, joins, starts its programs |
| Any x86-64 PC | `pc` | Official Debian installer, fully automatic | **Erases the PC's internal disk**, installs Debian and **powers off**. Remove the USB drive, power on: it installs Docker, joins, starts its programs |

- The first start needs internet once and takes 10-20 minutes (Docker and the
  program images are downloaded). Then the node appears in `./toolkit.sh nodes`
  and on the dashboard, and it comes back by itself after every reboot.
- Progress on the node: `journalctl -u sigint-firstboot` (or
  `/var/log/sigint-firstboot.log`). Log in with
  `ssh -i ~/.ssh/sigint_nodes sigint@<name>.local`; password login is disabled.
  By default nodes get a dedicated key, `~/.ssh/sigint_nodes` (made on first use),
  rather than your personal one: it gives passwordless root on every node.
- Only SD cards, USB drives and other removable disks are offered for writing,
  never a disk this machine is using. You type the device name to confirm, and
  the disk is checked again just before writing.
- The PC installer only installs when the PC has exactly one internal disk (USB
  disks are ignored), and stops if that disk already holds a SIGINT node, so
  leaving the drive plugged in can't trigger a second install.
- The base systems are downloaded once from raspberrypi.com / debian.org,
  checked against their published SHA-256 sums, and cached in `images/cache/`.
- Everything can be given as options for scripting, and `--image-only` just
  builds `images/<name>-<target>.img|.iso` for Raspberry Pi Imager or balenaEtcher
  ("Use custom"). See `./toolkit.sh flash-node --help`.

The card or drive holds the node's password and your Wi-Fi password. Keep it
private; if a device or card is lost, revoke it with `./toolkit.sh remove-node <name>`.
A PC's installer drive keeps them after installing, so reflash or wipe it afterwards.
If nodes connect through Cloudflare Access, they all share the master's Access
service token (`CLOUDFLARE_ACCESS_CLIENT_ID/SECRET`): after losing a device,
rotate it as well.

### Cloudflare

To link nodes that aren't on the master's network, without opening any ports,
use a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/):

1. In the Cloudflare dashboard, go to **Zero Trust → Networks → Tunnels**. Create a
   tunnel (connector type *cloudflared*) and copy its token.
2. Add a **public hostname** to the tunnel, for example `mqtt.example.com`, with
   service type **TCP** and URL **`broker:1884`**.
3. On the master, set these in `.env` and restart:
   ```ini
   CLOUDFLARE_TUNNEL_TOKEN=<token>
   MASTER_CLOUDFLARE_HOSTNAME=mqtt.example.com
   ```
   `./toolkit.sh up` now also starts `cloudflared`, and `add-node` prints a
   Cloudflare join command:
   ```bash
   ./toolkit.sh join --name van --master mqtt.example.com --cloudflare --password <printed password>
   ```
4. Optional but recommended: protect the hostname with a **Cloudflare Access**
   application and a **service token** policy, then pass the token when joining
   with `--cf-client-id <id> --cf-client-secret <secret>`.

On the node, a `master-link` container (`cloudflared access tcp`) opens the local
end of the tunnel, and the node's broker links through it. The node's own login
still applies on top of Cloudflare.

To reach the **dashboard** remotely as well, add a second public hostname with
service **HTTP** and URL **`api-public:8080`**, protect it with a Cloudflare Access
application, and give the master its team domain and AUD tag
(`CF_ACCESS_TEAM_DOMAIN`, `CF_ACCESS_AUD`; `./toolkit.sh setup` asks for them).
`api-public` is a second copy of the API that checks the Access login on every
request and refuses the rest, and the tunnel is on its own Docker network that
can't reach the login-free local API. So a missing or wrong Access policy can't
expose the dashboard.
Step by step: [docs/GUIDE.md](docs/GUIDE.md#reach-the-dashboard-from-anywhere).

## How programs talk to each other

Every program follows the same MQTT topic layout, where `<node>` is the device
it runs on (`NODE_NAME`, `master` on the master):

| Topic | Meaning |
|---|---|
| `sigint/<node>/<module>/data/<kind>` | Data a module produced. The ingestor **stores** it in the database. |
| `sigint/<node>/<module>/cmd/<command>` | A command sent **to** a module |
| `sigint/<node>/<module>/status` | Retained `online`/`offline` status, sent automatically |
| `sigint/<node>/node/status` | `1`/`0`: whether the node is linked to the master |

Payloads are JSON. So any program, in any language, can join by publishing JSON
to `sigint/<node>/<its name>/data/<kind>`. `rtl_433` does this with no extra code.
Programs log in to their device's broker with `MQTT_USERNAME` / `MQTT_PASSWORD`
from `.env`.

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

# Control a module on the master, or on any node
curl -X POST localhost:8080/api/modules/simulator/commands/set_rate -d '{"rate": 5}' -H 'content-type: application/json'
curl -X POST localhost:8080/api/nodes/roof-pi/modules/simulator/commands/pause -d '{}' -H 'content-type: application/json'
```

## The central database

| Table | Contents |
|---|---|
| `events` | Every data message: `id, ts, received, node, module, kind, topic, data (jsonb)`. `ts` is when it was collected, `received` when it reached the master |
| `modules` | Every program seen, per node: status, kind, metadata, first and last seen. The row named `node` is the node's link to the master |
| `kv` | Shared key/value store for config and state (`namespace, key, value`) |

Modules can also create their own tables, as `watchlist` does. Each insert into
`events` fires a `NOTIFY sigint_events`, so programs can react to new data from
SQL as well as from MQTT.

Example queries (`./toolkit.sh psql`):

```sql
SELECT node, module, kind, count(*) FROM events GROUP BY 1, 2, 3;
SELECT ts, data->>'callsign', data->>'altitude_ft' FROM events
 WHERE kind = 'adsb' AND data @> '{"callsign": "BAW123"}' ORDER BY ts DESC LIMIT 20;
```

## API

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Database and bus status |
| `GET /api/nodes` | All nodes, whether they are linked, and how many modules are online |
| `GET /api/modules?node=` | All modules and their status |
| `GET /api/events?node=&module=&kind=&since=&after_id=&contains=&limit=` | Query stored events (`contains` is a JSON filter) |
| `GET /api/events/{id}` | One event |
| `GET /api/stats` | Event counts per node, module and kind |
| `POST /api/publish` | Publish `{module, kind, data, node}` onto the bus |
| `POST /api/nodes/{node}/modules/{name}/commands/{command}` | Send a command to a module on any node |
| `POST /api/modules/{name}/commands/{command}` | Same, for a module on the master |
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

@mod.on("sigint/+/+/data/adsb")       # listen to other modules' data, on any node
def on_adsb(msg):
    print(msg.module, msg.data["callsign"])

@mod.command("scan")                  # POST /api/nodes/<node>/modules/wifi-scanner/commands/scan
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
  `sigint/<node>/<name>/data/<kind>` (`rtl_433`, AIS-catcher).
- **It has an API or network output:** write a small bridge that reads from
  it and calls `mod.publish()` (`services/bridges/` for Kismet, ADS-B and ChirpStack).
- **It's a command-line tool:** run it from a Python module and parse its
  output (`services/aprs/aprs.py`).

To use real hardware, pass the device to the container in `modules/compose.yml`
(for example `devices: ["/dev/bus/usb:/dev/bus/usb"]` for SDR dongles, or
`network_mode: host` with `cap_add: [NET_ADMIN, NET_RAW]` for Wi-Fi monitor mode).

## Security notes

- The database, broker, API and integration web UIs listen on `127.0.0.1`
  only by default. Two ports listen on all interfaces so other devices can reach
  them:
  - the master's node port 1884 (`NODE_LISTEN_ADDRESS`);
  - ChirpStack's gateway port 1700/udp (`LORA_BIND_ADDRESS`).
- Every connection to the master's broker needs a login: an internal account
  for the master's own programs, and one per node. Each node may publish only
  under its own name. On the local network that traffic is not encrypted, so
  use Cloudflare (which encrypts it) for nodes on networks you don't trust.
- Cards and drives made by `flash-node` (and the images in `images/`) contain
  the node's broker password and your Wi-Fi password. Treat them like keys.
  Nodes allow SSH only with the key you chose when flashing.
- The API has no login of its own; it listens on this machine only. Through
  Cloudflare it requires a valid Cloudflare Access login (checked by the API
  itself). Don't set `BIND_ADDRESS=0.0.0.0`: that would open it, unprotected,
  to your network.
- Only collect and decode signals you are legally permitted to receive in your
  jurisdiction.
