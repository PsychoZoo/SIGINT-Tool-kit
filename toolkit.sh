#!/usr/bin/env bash
# One-command launcher for the SIGINT Tool-kit stack.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage: ./toolkit.sh <command> [args]

  up [profiles...]     Build and start this device's stack plus the given profiles:
                         demo    simulator with fake data (no hardware)
                         kismet  Kismet Wi-Fi/Bluetooth monitor
                         lora    ChirpStack LoRaWAN server (master only)
                         adsb    aircraft  (RTL-SDR)     ais   ships (RTL-SDR)
                         ism     rtl_433   (RTL-SDR)     aprs  APRS  (RTL-SDR)
                         sdr     all four SDR programs   all   everything
  down                 Stop everything (data is kept)
  restart [service]    Restart one service, or the whole stack
  status               Show running services
  logs [service]       Follow logs (all services, or one)
  new-module <name>    Create modules/<name> from the template and add it to the stack
  reset                Stop everything and DELETE all stored data

Setting up:
  setup                Guided master setup: installs Docker if needed, asks a few
                       questions, starts the master, then offers to flash nodes
  flash-node [options] On the master: build a ready-to-run system for a new node
                       and write it to an SD card or USB drive (Raspberry Pi or PC).
                       See ./toolkit.sh flash-node --help
  test                 Run the shell tests (in Docker)

Multiple devices (one master, any number of nodes):
  add-node <name>      On the master: create a login for a node and print the
                       command to run on that node
  remove-node <name>   On the master: revoke a node's login
  nodes                On the master: list nodes and whether they are connected
  join --name <name> --master <host[:port]> --password <password>
       [--cloudflare] [--cf-client-id <id> --cf-client-secret <secret>]
                       On a new device: make it a node of that master
  role                 Show this device's role

Master only:
  psql                 Open a SQL shell on the central database
  migrate              Re-apply db/init/*.sql to an existing database
EOF
}

PROFILES=(demo kismet lora adsb ais ism aprs sdr all)
ALL_PROFILES=()
for p in "${PROFILES[@]}" master cloudflare-tunnel cloudflare-access; do ALL_PROFILES+=(--profile "$p"); done
NAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'

random_secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# shellcheck source=scripts/env.sh
source scripts/env.sh

ensure_env() {
  if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example."
  fi
  # Replace placeholder secrets with random ones, and add settings that are
  # new since .env was created.
  for key in POSTGRES_PASSWORD MQTT_PASSWORD KISMET_PASSWORD CHIRPSTACK_API_SECRET; do
    if ! grep -q "^${key}=" .env || grep -q "^${key}=change-me$" .env; then
      set_env "$key" "$(random_secret)"
    fi
  done
  while IFS= read -r line; do
    key=${line%%=*}
    if [[ "$line" == *=* && "$line" != \#* ]] && ! grep -q "^${key}=" .env; then
      echo "$line" >> .env
    fi
  done < .env.example
  if ! grep -q '^COMPOSE_FILE=.*integrations.yml' .env; then
    set_env COMPOSE_FILE docker-compose.yml:integrations.yml:modules/compose.yml
  fi
  # Base profiles for this device's role, so plain `docker compose` works too.
  set_env COMPOSE_PROFILES "$(role_profiles | tr ' ' ',')"
}

role() { env_value ROLE master; }

role_profiles() {
  if [[ "$(role)" == master ]]; then
    echo -n "master"
    [[ -n "$(env_value CLOUDFLARE_TUNNEL_TOKEN)" ]] && echo -n " cloudflare-tunnel"
  else
    [[ -n "$(env_value MASTER_CLOUDFLARE_HOSTNAME)" ]] && echo -n "cloudflare-access"
  fi
  echo
}

require_master() {
  if [[ "$(role)" != master ]]; then
    echo "'$1' only works on the master; this device is node '$(env_value NODE_NAME)'." >&2
    exit 1
  fi
}

compose() { docker compose "$@"; }

lan_address() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

reload_broker() {
  compose exec -T broker chown mosquitto /mosquitto/auth/passwd 2>/dev/null || true
  compose kill -s HUP broker >/dev/null
}

cmd=${1:-}
shift || true
case "$cmd" in
  up)
    ensure_env
    profiles=()
    for p in $(role_profiles); do profiles+=(--profile "$p"); done
    for profile in "$@"; do
      if [[ " ${PROFILES[*]} " != *" $profile "* ]]; then
        echo "unknown profile: $profile (expected one of: ${PROFILES[*]})" >&2
        exit 1
      fi
      if [[ "$(role)" == node && "$profile" =~ ^(lora|all)$ ]]; then
        echo "'$profile' includes ChirpStack, which needs the master's database; run it on the master." >&2
        exit 1
      fi
      profiles+=(--profile "$profile")
    done
    compose "${profiles[@]}" up -d --build --remove-orphans
    echo
    if [[ "$(role)" == master ]]; then
      port=$(env_value API_PORT 8080)
      echo "Master '$(env_value NODE_NAME master)'. Dashboard: http://localhost:${port}   Guide: http://localhost:${port}/guide"
      if [[ -n "$(env_value DASHBOARD_CLOUDFLARE_HOSTNAME)" ]]; then
        echo "From anywhere (Cloudflare Access login): https://$(env_value DASHBOARD_CLOUDFLARE_HOSTNAME)"
      fi
    else
      echo "Node '$(env_value NODE_NAME)', linked to the master at $(env_value MASTER_CLOUDFLARE_HOSTNAME "$(env_value MASTER_ADDRESS)")."
      echo "Its data appears on the master's dashboard. Check the link with: ./toolkit.sh logs broker"
    fi
    compose "${profiles[@]}" ps --services | while read -r svc; do
      case "$svc" in
        kismet)      echo "Kismet:     http://localhost:$(env_value KISMET_PORT 2501)  (user $(env_value KISMET_USER sigint), password in .env)" ;;
        chirpstack)  echo "ChirpStack: http://localhost:$(env_value CHIRPSTACK_PORT 8090)  (first login admin/admin)" ;;
        ultrafeeder) echo "ADS-B map:  http://localhost:$(env_value ADSB_MAP_PORT 8078)" ;;
        ais)         echo "AIS map:    http://localhost:$(env_value AIS_WEB_PORT 8100)" ;;
      esac
    done
    ;;
  down)     compose "${ALL_PROFILES[@]}" down --remove-orphans ;;
  restart)  compose restart "$@" ;;
  status)   compose "${ALL_PROFILES[@]}" ps ;;
  logs)     compose "${ALL_PROFILES[@]}" logs -f --tail=100 "$@" ;;
  role)
    ensure_env
    if [[ "$(role)" == master ]]; then
      echo "master (node name '$(env_value NODE_NAME master)')"
    else
      echo "node '$(env_value NODE_NAME)' of the master at $(env_value MASTER_CLOUDFLARE_HOSTNAME "$(env_value MASTER_ADDRESS)")"
    fi
    ;;
  psql)
    ensure_env; require_master psql
    compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    ;;
  migrate)
    ensure_env; require_master migrate
    for f in db/init/*.sql; do
      echo "applying $f"
      compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$f"
    done
    ;;
  add-node)
    ensure_env; require_master add-node
    name=${1:-}
    if [[ ! "$name" =~ $NAME_RE ]]; then
      echo "usage: ./toolkit.sh add-node <name>  (lowercase letters, digits, - and _)" >&2
      exit 1
    fi
    if [[ "$name" == "$(env_value NODE_NAME master)" || "$name" == "$(env_value MQTT_USERNAME local)" ]]; then
      echo "'$name' is reserved on this master; pick another node name." >&2
      exit 1
    fi
    password=$(random_secret)
    compose exec -T broker mosquitto_passwd -b /mosquitto/auth/passwd "$name" "$password"
    reload_broker
    if [[ "${2:-}" == --password-only ]]; then  # used by flash-node
      echo "$password"
      exit 0
    fi
    port=$(env_value NODE_PORT 1884)
    lan=$(lan_address)
    echo
    echo "Node '$name' can now connect. On that device, clone this repository and run:"
    echo
    echo "  Over the local network:"
    echo "    ./toolkit.sh join --name $name --master ${lan:-<master-IP>}:$port --password $password"
    cf_host=$(env_value MASTER_CLOUDFLARE_HOSTNAME)
    echo
    echo "  Through Cloudflare:"
    if [[ -n "$cf_host" ]]; then
      echo "    ./toolkit.sh join --name $name --master $cf_host --cloudflare --password $password"
    else
      echo "    set up the tunnel first (see \"Cloudflare\" in the README), then use"
      echo "    ./toolkit.sh join --name $name --master <your-hostname> --cloudflare --password $password"
    fi
    echo
    echo "Keep the password private: it lets a device send data as '$name'."
    ;;
  remove-node)
    ensure_env; require_master remove-node
    name=${1:?usage: ./toolkit.sh remove-node <name>}
    compose exec -T broker mosquitto_passwd -D /mosquitto/auth/passwd "$name"
    reload_broker
    compose restart broker >/dev/null  # drop the node's current connection
    echo "Removed node '$name'. Its stored data is kept."
    ;;
  nodes)
    ensure_env; require_master nodes
    echo "Nodes with a login:"
    compose exec -T broker cut -d: -f1 /mosquitto/auth/passwd | grep -v -x "$(env_value MQTT_USERNAME local)" | sed 's/^/  /' || true
    echo
    echo "Link status:"
    compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
      SELECT n.node, n.status, n.last_seen,
             count(m.name) FILTER (WHERE m.status = '"'"'online'"'"') AS modules_online
      FROM modules n LEFT JOIN modules m ON m.node = n.node AND m.name <> '"'"'node'"'"'
      WHERE n.name = '"'"'node'"'"' GROUP BY 1, 2, 3 ORDER BY 1"'
    ;;
  join)
    ensure_env
    # The password and secret can come from the environment instead of the
    # command line, where other users could see them (flashed nodes do this).
    name="" master="" password=${SIGINT_JOIN_PASSWORD:-} cloudflare=0 cf_id="" cf_secret=${SIGINT_JOIN_CF_SECRET:-}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name=$2; shift 2 ;;
        --master) master=$2; shift 2 ;;
        --password) password=$2; shift 2 ;;
        --cloudflare) cloudflare=1; shift ;;
        --cf-client-id) cf_id=$2; shift 2 ;;
        --cf-client-secret) cf_secret=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
      esac
    done
    if [[ ! "$name" =~ $NAME_RE || -z "$master" || -z "$password" ]]; then
      echo "usage: ./toolkit.sh join --name <name> --master <host[:port]> --password <password> [--cloudflare]" >&2
      exit 1
    fi
    set_env ROLE node
    set_env NODE_NAME "$name"
    set_env NODE_PASSWORD "$password"
    # Nothing on a node needs to be reachable from other machines.
    set_env NODE_LISTEN_ADDRESS 127.0.0.1
    if (( cloudflare )); then
      set_env MASTER_CLOUDFLARE_HOSTNAME "${master%%:*}"
      set_env MASTER_ADDRESS master-link:1884
      set_env CLOUDFLARE_ACCESS_CLIENT_ID "$cf_id"
      set_env CLOUDFLARE_ACCESS_CLIENT_SECRET "$cf_secret"
    else
      [[ "$master" == *:* ]] || master="$master:1884"
      set_env MASTER_ADDRESS "$master"
      set_env MASTER_CLOUDFLARE_HOSTNAME ""
    fi
    ensure_env
    echo "This device is now node '$name'. Start it (with whatever programs it should run), e.g.:"
    echo "  ./toolkit.sh up adsb kismet"
    ;;
  new-module)
    name=${1:-}
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
      echo "usage: ./toolkit.sh new-module <name>  (lowercase letters, digits, - and _)" >&2
      exit 1
    fi
    if [[ -e "modules/$name" ]]; then
      echo "modules/$name already exists" >&2
      exit 1
    fi
    cp -r modules/_template "modules/$name"
    sed -i.bak "s/__NAME__/$name/g" "modules/$name/main.py" "modules/$name/Dockerfile"
    rm -f "modules/$name"/*.bak
    cat >> modules/compose.yml <<EOF

  $name:
    <<: *module
    build:
      context: .
      dockerfile: modules/$name/Dockerfile
EOF
    echo "Created modules/$name. Edit modules/$name/main.py, then run: ./toolkit.sh up"
    ;;
  setup)       exec scripts/setup.sh "$@" ;;
  flash-node)  exec scripts/flash-node.sh "$@" ;;
  test)
    docker build -q --target test -t sigint-provision-test provision >/dev/null
    docker run --rm -v "$PWD:/code:ro" -w /code sigint-provision-test \
      sh -c 'shellcheck -x -S warning toolkit.sh scripts/*.sh provision/*.sh provision/pc/*.sh provision/firstboot/*.sh && bats tests'
    docker build -q -f services/api/tests/Dockerfile -t sigint-api-test . >/dev/null
    docker run --rm -v "$PWD:/code:ro" sigint-api-test
    # The real API image must at least start: import it and render the guide.
    docker build -q -f services/api/Dockerfile -t sigint-api-smoke . >/dev/null
    docker run --rm sigint-api-smoke python -c 'import main, guide; assert "Guide not found" not in guide.guide_page(); print("api image: ok")'
    ;;
  reset)
    read -r -p "This deletes ALL stored data on this device. Type 'yes' to continue: " answer
    [[ "$answer" == "yes" ]] && compose "${ALL_PROFILES[@]}" down -v
    ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
esac
