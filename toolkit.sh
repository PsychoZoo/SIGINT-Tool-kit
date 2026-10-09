#!/usr/bin/env bash
# One-command launcher for the SIGINT Tool-kit stack.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage: ./toolkit.sh <command> [args]

  up [demo] [sdr]      Build and start everything (optionally with the demo
                       simulator and/or the rtl_433 SDR receiver)
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

ensure_env() {
  if [[ ! -f .env ]]; then
    local password
    password=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${password}/" .env.example > .env
    echo "Created .env with a random database password."
  fi
}

compose() { docker compose "$@"; }

cmd=${1:-}
shift || true
case "$cmd" in
  up)
    ensure_env
    profiles=()
    for profile in "$@"; do
      case "$profile" in
        demo|sdr) profiles+=(--profile "$profile") ;;
        *) echo "unknown profile: $profile (expected demo or sdr)" >&2; exit 1 ;;
      esac
    done
    compose ${profiles[@]+"${profiles[@]}"} up -d --build
    port=$(grep -E '^API_PORT=' .env | cut -d= -f2)
    echo
    echo "Dashboard: http://localhost:${port:-8080}   API docs: http://localhost:${port:-8080}/docs"
    ;;
  down)     compose --profile demo --profile sdr down ;;
  restart)  compose restart "$@" ;;
  status)   compose --profile demo --profile sdr ps ;;
  logs)     compose --profile demo --profile sdr logs -f --tail=100 "$@" ;;
  psql)
    ensure_env
    compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    ;;
  migrate)
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
    [[ "$answer" == "yes" ]] && compose --profile demo --profile sdr down -v
    ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 1 ;;
esac
