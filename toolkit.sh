#!/usr/bin/env bash
# One-command launcher for the SIGINT Tool-kit stack.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage: ./toolkit.sh <command> [args]

  up [profiles...]     Build and start the core stack plus the given profiles:
                         demo    simulator with fake data (no hardware)
                         kismet  Kismet Wi-Fi/Bluetooth monitor
                         lora    ChirpStack LoRaWAN server
                         adsb    aircraft  (RTL-SDR)     ais   ships (RTL-SDR)
                         ism     rtl_433   (RTL-SDR)     aprs  APRS  (RTL-SDR)
                         sdr     all four SDR programs   all   everything
  down                 Stop everything (data is kept)
  restart [service]    Restart one service, or the whole stack
  status               Show running services
  logs [service]       Follow logs (all services, or one)
  psql                 Open a SQL shell on the central database
  migrate              Re-apply db/init/*.sql to an existing database
  new-module <name>    Create modules/<name> from the template and add it to the stack
  reset                Stop everything and DELETE all stored data
EOF
}

PROFILES=(demo kismet lora adsb ais ism aprs sdr all)
ALL_PROFILES=()
for p in "${PROFILES[@]}"; do ALL_PROFILES+=(--profile "$p"); done

random_secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ensure_env() {
  if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example."
  fi
  # Replace placeholder secrets with random ones, and add settings that are
  # new since .env was created.
  for key in POSTGRES_PASSWORD KISMET_PASSWORD CHIRPSTACK_API_SECRET; do
    if ! grep -q "^${key}=" .env; then
      echo "${key}=$(random_secret)" >> .env
    elif grep -q "^${key}=change-me$" .env; then
      sed -i.bak "s/^${key}=change-me$/${key}=$(random_secret)/" .env && rm -f .env.bak
    fi
  done
  while IFS= read -r line; do
    key=${line%%=*}
    if [[ "$line" == *=* && "$line" != \#* ]] && ! grep -q "^${key}=" .env; then
      echo "$line" >> .env
    fi
  done < .env.example
  if ! grep -q '^COMPOSE_FILE=.*integrations.yml' .env; then
    sed -i.bak 's#^COMPOSE_FILE=.*#COMPOSE_FILE=docker-compose.yml:integrations.yml:modules/compose.yml#' .env && rm -f .env.bak
  fi
}

compose() { docker compose "$@"; }

env_value() {  # env_value KEY DEFAULT
  local v
  v=$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)
  echo "${v:-$2}"
}

cmd=${1:-}
shift || true
case "$cmd" in
  up)
    ensure_env
    profiles=()
    for profile in "$@"; do
      if [[ " ${PROFILES[*]} " != *" $profile "* ]]; then
        echo "unknown profile: $profile (expected one of: ${PROFILES[*]})" >&2
        exit 1
      fi
      profiles+=(--profile "$profile")
    done
    compose ${profiles[@]+"${profiles[@]}"} up -d --build
    port=$(env_value API_PORT 8080)
    echo
    echo "Dashboard: http://localhost:${port:-8080}   API docs: http://localhost:${port:-8080}/docs"
    compose ${profiles[@]+"${profiles[@]}"} ps --services | while read -r svc; do
      case "$svc" in
        kismet)      echo "Kismet:     http://localhost:$(env_value KISMET_PORT 2501)  (user $(env_value KISMET_USER sigint), password in .env)" ;;
        chirpstack)  echo "ChirpStack: http://localhost:$(env_value CHIRPSTACK_PORT 8090)  (first login admin/admin)" ;;
        ultrafeeder) echo "ADS-B map:  http://localhost:$(env_value ADSB_MAP_PORT 8078)" ;;
        ais)         echo "AIS map:    http://localhost:$(env_value AIS_WEB_PORT 8100)" ;;
      esac
    done
    ;;
  down)     compose "${ALL_PROFILES[@]}" down ;;
  restart)  compose restart "$@" ;;
  status)   compose "${ALL_PROFILES[@]}" ps ;;
  logs)     compose "${ALL_PROFILES[@]}" logs -f --tail=100 "$@" ;;
  psql)
    ensure_env
    compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    ;;
  migrate)
    ensure_env
    for f in db/init/*.sql; do
      echo "applying $f"
      compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$f"
    done
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
  reset)
    read -r -p "This deletes ALL stored data. Type 'yes' to continue: " answer
    [[ "$answer" == "yes" ]] && compose "${ALL_PROFILES[@]}" down -v
    ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
esac
