#!/usr/bin/env bash
# First boot of a node flashed by `./toolkit.sh flash-node`. Runs as root from
# sigint-firstboot.service until it succeeds:
#   1. waits for the network
#   2. installs Docker
#   3. unpacks the toolkit, joins the master and starts the chosen programs
# Safe to re-run: every step checks whether it is already done.
#
# Progress: journalctl -u sigint-firstboot  (also /var/log/sigint-firstboot.log)
set -euo pipefail
umask 077  # the log and anything else written here: root only

PROV=${SIGINT_PROVISION_DIR:-/opt/sigint-provision}
APP=${SIGINT_APP_DIR:-/opt/sigint-toolkit}
DONE=${SIGINT_DONE_FILE:-/var/lib/sigint/provisioned}
NETWORK_TIMEOUT=600  # seconds; systemd restarts us if the network never comes up

exec > >(tee -a "${SIGINT_LOG_FILE:-/var/log/sigint-firstboot.log}") 2>&1
log() { echo "[sigint-firstboot] $*"; }

if [[ -f "$DONE" ]]; then
  log "already provisioned"
  exit 0
fi

# shellcheck source=/dev/null
source "$PROV/node.env"   # NODE_NAME MASTER NODE_PASSWORD PROGRAMS CLOUDFLARE CF_* NODE_USER

wait_for_network() {
  local waited=0
  until curl -fsS --max-time 10 -o /dev/null https://download.docker.com/; do
    if (( waited >= NETWORK_TIMEOUT )); then
      log "no internet after ${NETWORK_TIMEOUT}s; will retry"
      return 1
    fi
    sleep 10
    waited=$((waited + 10))
  done
}

blacklist_dvb() {
  local conf=${SIGINT_MODPROBE_CONF:-/etc/modprobe.d/blacklist-rtlsdr.conf}
  if [[ -f "$conf" ]]; then return 0; fi
  log "blacklisting the DVB-T driver so SDR programs can use the dongles"
  printf 'blacklist dvb_usb_rtl28xxu\nblacklist rtl2832\nblacklist rtl2830\n' > "$conf"
  modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
}

unpack_toolkit() {
  if [[ -x "$APP/toolkit.sh" ]]; then return 0; fi
  log "unpacking the toolkit to $APP"
  mkdir -p "$APP"
  tar -xzf "$PROV/toolkit.tar.gz" -C "$APP"
}

join_master() {
  local args=(join --name "$NODE_NAME" --master "$MASTER")
  if [[ "$CLOUDFLARE" == 1 ]]; then
    args+=(--cloudflare)
    if [[ -n "$CF_CLIENT_ID" ]]; then args+=(--cf-client-id "$CF_CLIENT_ID"); fi
  fi
  log "joining the master at $MASTER as '$NODE_NAME'"
  # Secrets go through the environment, not the command line (visible in ps).
  (cd "$APP" && SIGINT_JOIN_PASSWORD=$NODE_PASSWORD SIGINT_JOIN_CF_SECRET=$CF_CLIENT_SECRET ./toolkit.sh "${args[@]}")
  chmod 600 "$APP/.env"
}

main() {
  log "provisioning node '$NODE_NAME' (programs: ${PROGRAMS:-none})"
  wait_for_network
  if ! docker compose version >/dev/null 2>&1; then
    log "installing Docker"
    bash "$PROV/install-docker.sh"
  fi
  id -u "$NODE_USER" >/dev/null 2>&1 && usermod -aG docker "$NODE_USER"
  # shellcheck source=provision/lib.sh
  source "$PROV/lib.sh"
  programs_need_sdr "$PROGRAMS" && blacklist_dvb
  unpack_toolkit
  join_master
  log "starting the node's programs (the first start downloads and builds images, this takes a while)"
  # shellcheck disable=SC2086  # PROGRAMS is a space-separated list of profile names
  (cd "$APP" && ./toolkit.sh up $PROGRAMS)
  if [[ -n "$NODE_USER" ]]; then chown -R "$NODE_USER:" "$APP"; fi
  mkdir -p "$(dirname "$DONE")"
  date -u +%FT%TZ > "$DONE"
  rm -f "$PROV/node.env"  # the password now lives only in $APP/.env (mode 600)
  log "done: node '$NODE_NAME' is running and linked to $MASTER"
}

main
