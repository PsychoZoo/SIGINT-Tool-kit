#!/usr/bin/env bash
# ./toolkit.sh flash-node: on the master, build a ready-to-run system for a new
# node and write it to an SD card or USB drive. The node boots, installs Docker,
# joins this master and starts its programs with nobody logging in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=provision/lib.sh
source provision/lib.sh
# shellcheck source=scripts/env.sh
source scripts/env.sh

BUILDER_IMAGE=sigint-provision
IMAGES_DIR=$PWD/images

usage() {
  cat <<'EOF'
Usage: ./toolkit.sh flash-node [options]

Builds a system for a new node and writes it to an SD card or USB drive.
Anything not given as an option is asked for.

  --name NAME            node name (lowercase letters, digits, - and _)
  --target pi|pc         pi: Raspberry Pi 3/4/5/Zero 2 W (64-bit Raspberry Pi OS)
                         pc: any x86-64 PC (unattended Debian install that ERASES
                             the PC's internal disk, then powers off)
  --programs "LIST"      programs the node runs: demo kismet adsb ais ism aprs sdr
  --wifi-ssid SSID       Wi-Fi network ("" = Ethernet only). The password is asked
                         for, or read from FLASH_WIFI_PASSWORD
  --wifi-country CC      Wi-Fi country code, e.g. US, GB, DE
  --ssh-key FILE|none    public key allowed to log in as 'sigint' over SSH
                         (default: a dedicated key, ~/.ssh/sigint_nodes, made if missing)
  --master HOST[:PORT]   address the node connects to (default: this machine's
                         LAN address; give the Cloudflare hostname to go through it)
  --device /dev/XXX      card or drive to write (must be removable/USB)
  --image-only           only build images/<name>-<target>.img|.iso, don't write it
EOF
}

# --- settings -----------------------------------------------------------------------

name="" target="" programs="" ssid="" ssid_set=0 country="" ssh_key_file=""
master="" device="" image_only=0 wifi_password=${FLASH_WIFI_PASSWORD:-}
programs_set=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name=$2; shift 2 ;;
      --target) target=$2; shift 2 ;;
      --programs) programs=$2; programs_set=1; shift 2 ;;
      --wifi-ssid) ssid=$2; ssid_set=1; shift 2 ;;
      --wifi-country) country=$2; shift 2 ;;
      --ssh-key) ssh_key_file=$2; shift 2 ;;
      --master) master=$2; shift 2 ;;
      --device) device=$2; shift 2 ;;
      --image-only) image_only=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done
}

existing_nodes() {
  # </dev/null: docker compose exec forwards stdin, which would eat the answers
  # to our prompts.
  docker compose exec -T broker cut -d: -f1 /mosquitto/auth/passwd 2>/dev/null </dev/null \
    | grep -v -x "$(env_value MQTT_USERNAME local)" || true
}

next_free_name() {  # next_free_name prefix -> prefix-1, prefix-2, ...
  local taken n=1
  taken=" $(existing_nodes | tr '\n' ' ') "
  while [[ "$taken" == *" $1-$n "* ]]; do n=$((n + 1)); done
  echo "$1-$n"
}

host_timezone() {
  local tz
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -z "$tz" ]] && tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
  [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] && echo "$tz" || echo UTC
}

# A key just for nodes, rather than your personal one: whoever has it is root on
# every node (passwordless sudo), and nodes sit in the field.
NODES_KEY=~/.ssh/sigint_nodes

ensure_nodes_key() {
  if [[ -f "$NODES_KEY.pub" ]]; then return 0; fi
  echo "Creating an SSH key for logging in to nodes: $NODES_KEY (a passphrase is recommended)"
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -q -t ed25519 -C "sigint-nodes" -f "$NODES_KEY"
}

default_master() {
  local lan
  lan=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${lan:-}:$(env_value NODE_PORT 1884)"
}

collect_settings() {
  [[ -n "$target" ]] || ask target "Device type, pi (Raspberry Pi) or pc" "$(env_value FLASH_TARGET pi)"
  valid_target "$target" || die "device type must be pi or pc"
  [[ -n "$name" ]] || ask name "Node name" "$(next_free_name "$target")"
  valid_node_name "$name" || die "node name: lowercase letters, digits, - and _ (max 32)"
  if (( ! programs_set )); then
    ask programs "Programs to run (${NODE_PROGRAMS[*]})" "$(env_value FLASH_PROGRAMS demo)"
  fi
  valid_programs "$programs" || die "programs must be from: ${NODE_PROGRAMS[*]} (lora runs on the master only)"
  collect_wifi
  [[ -n "$ssh_key_file" ]] || ask ssh_key_file "SSH public key for logging in to the node (or none)" "$(env_value FLASH_SSH_KEY "$NODES_KEY.pub")"
  ssh_key=""
  if [[ "$ssh_key_file" != none ]]; then
    ssh_key_file=${ssh_key_file/#\~/$HOME}
    if [[ "$ssh_key_file" == "$NODES_KEY.pub" ]]; then ensure_nodes_key; fi
    ssh_key=$(head -n1 "$ssh_key_file" 2>/dev/null) || die "can't read $ssh_key_file"
    valid_ssh_pubkey "$ssh_key" || die "$ssh_key_file is not an SSH public key (use the .pub file)"
  fi
  local cf_hint=""
  if [[ -n "$(env_value MASTER_CLOUDFLARE_HOSTNAME)" ]]; then cf_hint=" (or $(env_value MASTER_CLOUDFLARE_HOSTNAME) for Cloudflare)"; fi
  [[ -n "$master" ]] || ask master "Master address the node connects to$cf_hint" "$(default_master)"
  [[ "$master" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ && "$master" != :* ]] || die "master address must be host or host:port"
  timezone=$(host_timezone)
}

collect_wifi() {
  if (( ! ssid_set )); then
    ask ssid "Wi-Fi network name (leave empty for Ethernet only)" "$(env_value FLASH_WIFI_SSID)"
  fi
  if [[ -z "$ssid" ]]; then return 0; fi
  valid_ssid "$ssid" || die "Wi-Fi name must be one line of at most 32 bytes, not ending in \\"
  [[ -n "$country" ]] || ask country "Wi-Fi country code (US, GB, DE, ...)" "$(env_value FLASH_WIFI_COUNTRY US)"
  valid_country "$country" || die "country must be a two-letter code in capitals, e.g. US"
  if [[ -z "$wifi_password" ]]; then
    read -r -s -p "Wi-Fi password for '$ssid': " wifi_password || die "no Wi-Fi password"
    echo
  fi
  valid_wifi_password "$wifi_password" || die "Wi-Fi password must be 8-63 characters, not ending in \\"
}

remember_settings() {
  set_env FLASH_TARGET "$target"
  set_env FLASH_PROGRAMS "$programs"
  set_env FLASH_WIFI_SSID "$ssid"
  if [[ -n "$country" ]]; then set_env FLASH_WIFI_COUNTRY "$country"; fi
  set_env FLASH_SSH_KEY "$ssh_key_file"
}

# --- building ------------------------------------------------------------------------

require_running_master() {
  [[ "$(env_value ROLE master)" == master ]] || die "flash-node runs on the master; this device is a node"
  docker compose ps --status running --services 2>/dev/null | grep -qx broker \
    || die "the master isn't running; start it first with ./toolkit.sh up (or ./toolkit.sh setup)"
}

create_login() {
  if existing_nodes | grep -qx "$name"; then
    local answer
    ask answer "Node '$name' already exists. Replace its login (its current card stops working)? y/N" n
    [[ "$answer" =~ ^[Yy] ]] || die "pick another name"
  fi
  node_password=$(./toolkit.sh add-node "$name" --password-only </dev/null | tail -n1)
  [[ "$node_password" =~ ^[0-9a-f]{48}$ ]] || die "couldn't create a login for '$name'"
  login_created=1
}

# On any failure after the login was made: revoke it (no unused working login
# left on the broker) and remove the half-built files.
cleanup_on_exit() {
  local status=$?
  if [[ -n "${work:-}" ]]; then rm -rf "$work"; fi
  if (( status != 0 && login_created )); then
    echo "Revoking the login made for '$name', since flashing didn't finish." >&2
    ./toolkit.sh remove-node "$name" >/dev/null 2>&1 || true
  fi
}

# Files never shipped to nodes, even if not git-ignored.
bundle_excluded() {
  case "$1" in
    .env.example) return 1 ;;
    .env|.env.*|*/.env|*/.env.*|*.pem|*.key|*.p12|broker/auth/*|images/*) return 0 ;;
  esac
  return 1
}

bundle_toolkit() {  # bundle_toolkit OUT.tar.gz: the repo as this master has it, without secrets
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "flash-node needs the toolkit as a git checkout"
  git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do
        if [[ -e "$f" ]] && ! bundle_excluded "$f"; then printf '%s\0' "$f"; fi
      done \
    | tar --null -T - -czf "$1"
}

write_payload() {  # write_payload DIR
  local dir=$1 s=$1/sigint cloudflare=0
  mkdir -p "$s"
  if [[ "$master" == "$(env_value MASTER_CLOUDFLARE_HOSTNAME)" ]]; then cloudflare=1; fi
  render_node_env "$name" "$master" "$node_password" "$programs" "$cloudflare" \
    "$(env_value CLOUDFLARE_ACCESS_CLIENT_ID)" "$(env_value CLOUDFLARE_ACCESS_CLIENT_SECRET)" > "$s/node.env"
  bundle_toolkit "$s/toolkit.tar.gz"
  cp provision/firstboot/sigint-firstboot.sh provision/firstboot/sigint-firstboot.service \
     provision/install-docker.sh provision/lib.sh "$s/"
  if [[ "$target" == pi ]]; then
    render_pi_user_data "$name" "$timezone" "$ssh_key" > "$dir/user-data"
    render_pi_network_config "$ssid" "$wifi_password" "$country" > "$dir/network-config"
    render_pi_meta_data "$name" > "$dir/meta-data"
  else
    render_preseed "$name" "$timezone" "$ssid" "$wifi_password" > "$dir/preseed.cfg"
    render_grub_entry "$name" > "$dir/grub-entry.cfg"
    render_isolinux "$name" > "$dir/isolinux.cfg"
    cp provision/pc/pick-disk.sh provision/pc/late.sh "$s/"
    if [[ -n "$ssh_key" ]]; then echo "$ssh_key" > "$s/authorized_keys"; fi
    if [[ -n "$ssid" ]]; then render_wifi_keyfile "$ssid" "$wifi_password" > "$s/sigint-wifi.nmconnection"; fi
  fi
}

build_image() {
  local ext=img
  if [[ "$target" == pc ]]; then ext=iso; fi
  image=$IMAGES_DIR/$name-$target.$ext
  mkdir -p "$IMAGES_DIR"
  chmod 700 "$IMAGES_DIR"
  work=$(mktemp -d "$IMAGES_DIR/.build-XXXXXX")
  write_payload "$work"
  echo "Building the image (the first time downloads the base system)..."
  docker build -q --target builder -t "$BUILDER_IMAGE" provision >/dev/null
  docker run --rm --user "$(id -u):$(id -g)" -v "$IMAGES_DIR:/images" "$BUILDER_IMAGE" \
    "$target" "/images/${work##*/}" "/images/${image##*/}"
  chmod 600 "$image"
  rm -rf "$work"
  work=""
}

main() {
  trap cleanup_on_exit EXIT
  parse_args "$@"
  require_running_master
  collect_settings
  create_login
  build_image
  remember_settings
  if (( image_only )); then
    echo "Image ready: $image"
    echo "Write it with Raspberry Pi Imager / balenaEtcher ('Use custom'), or run flash-node again without --image-only."
    echo "It contains this node's password and your Wi-Fi password: keep it private, delete it when done."
    return
  fi
  # shellcheck source=scripts/flash-write.sh
  source scripts/flash-write.sh
  write_to_card "$image" "$device"
  login_created=0  # flashed: the login is in use now
  print_next_steps
  offer_delete_image
  offer_another
}

offer_delete_image() {
  local answer
  ask answer "Delete $(basename "$image")? It holds this node's password and your Wi-Fi password. Y/n" y
  if [[ "$answer" =~ ^[Yy] ]]; then rm -f "$image" && echo "Deleted."; fi
  return 0
}

offer_another() {
  local answer
  echo
  ask answer "Flash another $target node with the same settings? y/N" n
  [[ "$answer" =~ ^[Yy] ]] || return 0
  local args=(--target "$target" --programs "$programs" --wifi-ssid "$ssid" --master "$master"
              --ssh-key "${ssh_key_file:-none}")
  if [[ -n "$country" ]]; then args+=(--wifi-country "$country"); fi
  FLASH_WIFI_PASSWORD=$wifi_password exec "$0" "${args[@]}"
}

print_next_steps() {
  echo
  if [[ "$target" == pi ]]; then
    echo "Done. Put the card in the Raspberry Pi and power it on."
  else
    echo "Done. Boot the PC from this USB drive (boot menu key: often F12, F11, F8 or Esc)."
    echo "It ERASES the PC's internal disk, installs, then powers off. Remove the drive and power it on."
    echo "The drive still holds this node's password and your Wi-Fi password: reflash or wipe it afterwards."
  fi
  echo "It installs Docker and its programs on first start (10-20 minutes), then shows up as"
  echo "'$name' in ./toolkit.sh nodes and on the dashboard."
  if [[ -n "$ssh_key" ]]; then echo "Log in with: ssh sigint@$name.local"; fi
  echo "Lost card? Revoke it with: ./toolkit.sh remove-node $name"
}

work="" login_created=0
# Run unless sourced (the tests source this file to call its functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
