#!/usr/bin/env bash
# ./toolkit.sh setup: guided setup of this machine as the master. Installs Docker
# if needed, asks a few questions, starts the master, then offers to flash SD
# cards / USB drives for nodes.
# Safe to run again: every answer defaults to the current setting.
set -euo pipefail
cd "$(dirname "$0")/.."
SELF=$PWD/scripts/setup.sh
# shellcheck source=provision/lib.sh
source provision/lib.sh
# shellcheck source=scripts/env.sh
source scripts/env.sh

MASTER_PROGRAMS=(demo kismet lora adsb ais ism aprs sdr all)

yes_no() {  # yes_no "question" Y|N -> success for yes
  local answer
  ask answer "$1 $([[ $2 == Y ]] && echo Y/n || echo y/N)" "$2"
  [[ "$answer" =~ ^[Yy] ]]
}

step_docker() {
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker (with the Compose plugin) is not installed."
    yes_no "Install it now (needs sudo)?" Y || die "the toolkit needs Docker; install it and run setup again"
    sudo bash provision/install-docker.sh
  fi
  docker info >/dev/null 2>&1 && return 0
  if [[ -n "${SIGINT_SETUP_REGROUPED:-}" ]]; then
    die "can't reach Docker. Is it running? Try: sudo systemctl enable --now docker"
  fi
  local me
  me=$(id -un)
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    echo "Adding $me to the 'docker' group so the toolkit can use Docker without sudo."
    echo "(Members of that group can control Docker, which is as powerful as root.)"
    sudo usermod -aG docker "$me"
    sudo systemctl enable --now docker
  fi
  # This shell doesn't have the new group yet. sudo -u re-reads our groups, so
  # setup continues in a process that has it. (Log out and back in once, so
  # other terminals get it too.)
  exec sudo -u "$me" env SIGINT_SETUP_REGROUPED=1 "$SELF" "$@"
}

step_role() {
  if [[ "$(env_value ROLE master)" == master ]]; then return 0; fi
  echo "This device is currently node '$(env_value NODE_NAME)' of another master."
  yes_no "Make it a master instead?" N || die "setup sets up a master; nothing changed"
  ./toolkit.sh down
  set_env ROLE master
  set_env NODE_NAME master
  set_env MASTER_ADDRESS ""
  set_env NODE_PASSWORD ""
  set_env NODE_LISTEN_ADDRESS 0.0.0.0
}

step_questions() {
  local name cf_token cf_host
  ask name "Name for this master" "$(env_value NODE_NAME master)"
  valid_node_name "$name" || die "name: lowercase letters, digits, - and _ (max 32)"
  set_env NODE_NAME "$name"

  ask programs "Programs to run on the master (${MASTER_PROGRAMS[*]}, or none)" "$(env_value SETUP_PROGRAMS demo)"
  if [[ "$programs" == none ]]; then programs=""; fi
  local p
  for p in $programs; do
    [[ " ${MASTER_PROGRAMS[*]} " == *" $p "* ]] || die "unknown program '$p'"
  done
  set_env SETUP_PROGRAMS "${programs:-none}"

  if yes_no "Also let nodes connect from outside this network through Cloudflare?" N; then
    echo "See \"Cloudflare\" in the README for creating the tunnel."
    ask cf_token "Cloudflare tunnel token" "$(env_value CLOUDFLARE_TUNNEL_TOKEN)"
    ask cf_host "Public hostname routed to tcp://broker:1884 (e.g. mqtt.example.com)" "$(env_value MASTER_CLOUDFLARE_HOSTNAME)"
    if ! valid_line "$cf_token" || [[ ! "$cf_host" =~ ^[A-Za-z0-9.-]+$ ]]; then
      die "invalid Cloudflare settings"
    fi
    set_env CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
    set_env MASTER_CLOUDFLARE_HOSTNAME "$cf_host"
  fi
}

# Docker publishes the node port itself, past ufw/firewalld rules, so there is
# nothing to open; this only says how to narrow it.
note_node_port() {
  local port
  port=$(env_value NODE_PORT 1884)
  echo "Nodes connect to this machine on port $port (all network interfaces)."
  echo "To accept them on one address only, set NODE_LISTEN_ADDRESS=<that address> in .env."
}

main() {
  echo "Setting up this machine as the SIGINT Tool-kit master."
  step_docker "$@"
  step_role
  step_questions
  note_node_port
  # shellcheck disable=SC2086  # programs is a space-separated list of profiles
  ./toolkit.sh up $programs
  echo
  if yes_no "Flash SD cards or USB drives for nodes now?" Y; then
    exec "$PWD/scripts/flash-node.sh"
  fi
  echo "Flash nodes any time with: ./toolkit.sh flash-node"
}

programs=""
main "$@"
