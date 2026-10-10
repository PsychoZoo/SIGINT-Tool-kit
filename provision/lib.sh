# shellcheck shell=bash
# Shared helpers for building node media: input checks, config rendering and
# picking which disks may be written. Sourced by scripts/flash-node.sh,
# scripts/setup.sh and the tests; it only defines functions.
#
# Every render_* function prints a complete file to stdout.

# Programs a node may run. `lora` and `all` include ChirpStack, which needs the
# master's database, so they are master only (same rule as `toolkit.sh up`).
NODE_PROGRAMS=(demo kismet adsb ais ism aprs sdr)
SDR_PROGRAMS=(adsb ais ism aprs sdr)
NODE_NAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'

# User account created on every node. Password login is disabled; log in with
# the SSH key given when flashing.
NODE_USER=sigint

die() { echo "error: $*" >&2; exit 1; }

ask() {  # ask VAR "question" [default] -> sets VAR to the answer or the default
  # (The local's name must not match any caller's VAR, or printf -v sets ours.)
  local _ask_reply
  read -r -p "$2${3:+ [$3]}: " _ask_reply || die "no answer for: $2"
  printf -v "$1" '%s' "${_ask_reply:-${3:-}}"
}

valid_node_name() { [[ "$1" =~ $NODE_NAME_RE ]]; }

valid_target() { [[ "$1" == pi || "$1" == pc ]]; }

# Two-letter Wi-Fi regulatory country code, e.g. US, GB, DE.
valid_country() { [[ "$1" =~ ^[A-Z]{2}$ ]]; }

valid_ssh_pubkey() {
  [[ "$1" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]]
}

# A value that ends up inside a config file: one printable line. A trailing
# backslash is refused too: the Debian installer reads it as a line continuation.
valid_line() { [[ "$1" != *[[:cntrl:]]* && "$1" != *\\ ]]; }

byte_length() { LC_ALL=C; echo "${#1}"; }

# WPA2 passphrase: 8-63 printable characters.
valid_wifi_password() {
  valid_line "$1" && (( $(byte_length "$1") >= 8 && $(byte_length "$1") <= 63 ))
}

# Wi-Fi network name: one line, at most 32 bytes.
valid_ssid() { valid_line "$1" && (( $(byte_length "$1") <= 32 )); }

# valid_programs "adsb ism" -> success if every word is a node program.
valid_programs() {
  local p
  for p in $1; do
    [[ " ${NODE_PROGRAMS[*]} " == *" $p "* ]] || return 1
  done
}

programs_need_sdr() {
  local p
  for p in $1; do
    [[ " ${SDR_PROGRAMS[*]} " == *" $p "* ]] && return 0
  done
  return 1
}

# YAML double-quoted scalar.
yaml_quote() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Value for a NetworkManager keyfile (GLib key file): escape backslashes and
# leading/trailing spaces.
keyfile_escape() {
  local s=${1//\\/\\\\}
  [[ "$s" == " "* ]] && s="\\s${s:1}"
  [[ "$s" == *" " ]] && s="${s%?}\\s"
  printf '%s' "$s"
}

# --- Raspberry Pi (cloud-init on the boot partition) ---------------------------

render_pi_meta_data() {  # name
  printf 'instance-id: sigint-%s\nlocal-hostname: %s\n' "$1" "$1"
}

render_pi_user_data() {  # name timezone ssh_key(optional)
  local name=$1 tz=$2 key=${3:-}
  cat <<EOF
#cloud-config
# Written by ./toolkit.sh flash-node. Sets up node '$name', then hands over to
# sigint-firstboot.service, which installs Docker and joins the master.
hostname: $name
manage_etc_hosts: true
timezone: $(yaml_quote "$tz")
users:
  - name: $NODE_USER
    groups: [users, adm, dialout, plugdev, netdev, video, gpio, spi, i2c, sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
EOF
  if [[ -n "$key" ]]; then
    printf '    ssh_authorized_keys:\n      - %s\nenable_ssh: true\n' "$(yaml_quote "$key")"
  fi
  cat <<'EOF'
ssh_pwauth: false
runcmd:
  - [sh, -c, "install -d -m 0700 /opt/sigint-provision && cp -r /boot/firmware/sigint/. /opt/sigint-provision/ && rm -rf /boot/firmware/sigint"]
  - [install, -m, "0644", /opt/sigint-provision/sigint-firstboot.service, /etc/systemd/system/sigint-firstboot.service]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, --no-block, sigint-firstboot.service]
EOF
}

render_pi_network_config() {  # ssid password country (ssid may be empty: Ethernet only)
  local ssid=$1 pass=$2 country=$3
  # Raspberry Pi OS runs NetworkManager: render everything for it. (Per-section
  # renderers would send eth0 to systemd-networkd, which isn't running there.)
  cat <<'EOF'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    eth0:
      dhcp4: true
      optional: true
EOF
  [[ -z "$ssid" ]] && return 0
  cat <<EOF
  wifis:
    wlan0:
      dhcp4: true
      regulatory-domain: $(yaml_quote "$country")
      access-points:
        $(yaml_quote "$ssid"):
          password: $(yaml_quote "$pass")
      optional: true
EOF
}

# --- PC (Debian installer preseed) ---------------------------------------------

render_preseed() {  # name timezone [ssid password]
  local name=$1 tz=$2 ssid=${3:-} pass=${4:-}
  if [[ -n "$ssid" ]]; then
    # Used only if the installer finds no wired connection.
    printf 'd-i netcfg/wireless_essid string %s\n' "$ssid"
    printf 'd-i netcfg/wireless_security_type select wpa\n'
    printf 'd-i netcfg/wireless_wpa string %s\n' "$pass"
  fi
  cat <<EOF
# Debian unattended install for SIGINT node '$name'. Written by ./toolkit.sh flash-node.
# ERASES the first internal disk, installs Debian, then powers off.
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $name
d-i netcfg/get_domain string local
d-i netcfg/hostname string $name
d-i hw-detect/load_firmware boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean false
d-i passwd/user-fullname string SIGINT node
d-i passwd/username string $NODE_USER
# Random throwaway password (filled in by build-image.sh); late.sh locks the
# account's password. Log in with the SSH key.
d-i passwd/user-password-crypted password @PASSWORD_HASH@
d-i clock-setup/utc boolean true
d-i time/zone string $tz
d-i clock-setup/ntp boolean true
d-i partman/early_command string sh /cdrom/sigint/pick-disk.sh
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-efi/non_efi_system boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string avahi-daemon ca-certificates curl network-manager wpasupplicant
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i preseed/late_command string sh /cdrom/sigint/late.sh
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF
}

# Kernel arguments that start the unattended install.
INSTALLER_ARGS='auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=en_US.UTF-8 keymap=us'

render_grub_entry() {  # name
  cat <<EOF
# --- SIGINT node '$1': automatic install (added by ./toolkit.sh flash-node) ---
set default=0
set timeout=5
menuentry "SIGINT node $1: automatic install (ERASES the internal disk)" {
    linux    /install.amd/vmlinuz $INSTALLER_ARGS --- quiet
    initrd   /install.amd/initrd.gz
}
EOF
}

render_isolinux() {  # name
  cat <<EOF
# SIGINT node '$1': automatic install (ERASES the internal disk) after 5 seconds.
default sigint
prompt 1
timeout 50
label sigint
  kernel /install.amd/vmlinuz
  append $INSTALLER_ARGS vga=788 initrd=/install.amd/initrd.gz --- quiet
EOF
}

render_wifi_keyfile() {  # ssid password
  cat <<EOF
[connection]
id=sigint-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$(keyfile_escape "$1")

[wifi-security]
key-mgmt=wpa-psk
psk=$(keyfile_escape "$2")

[ipv4]
method=auto

[ipv6]
method=auto
EOF
}

# --- Node settings read by sigint-firstboot.sh ---------------------------------

render_node_env() {  # name master password programs cloudflare(0|1) cf_id cf_secret
  printf 'NODE_NAME=%q\n' "$1"
  printf 'MASTER=%q\n' "$2"
  printf 'NODE_PASSWORD=%q\n' "$3"
  printf 'PROGRAMS=%q\n' "$4"
  printf 'CLOUDFLARE=%q\n' "$5"
  printf 'CF_CLIENT_ID=%q\n' "${6:-}"
  printf 'CF_CLIENT_SECRET=%q\n' "${7:-}"
  printf 'NODE_USER=%q\n' "$NODE_USER"
}

# --- Choosing a disk to write ---------------------------------------------------

# Reads `lsblk -dnbP -o PATH,SIZE,TYPE,RM,HOTPLUG,TRAN,MODEL` on stdin and prints
# the paths of disks that may be flashed: removable-media, USB or SD-card disks
# with a size, never one listed in $1 (space-separated disks in use by this
# system, e.g. "/dev/nvme0n1"). HOTPLUG alone doesn't count: internal SATA bays
# often report it.
filter_flash_disks() {
  local system_disks=" ${1:-} " line path size type rm tran
  local re='PATH="([^"]*)" SIZE="([^"]*)" TYPE="([^"]*)" RM="([^"]*)" HOTPLUG="([^"]*)" TRAN="([^"]*)"'
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    path=${BASH_REMATCH[1]} size=${BASH_REMATCH[2]} type=${BASH_REMATCH[3]}
    rm=${BASH_REMATCH[4]} tran=${BASH_REMATCH[6]}
    [[ "$type" == disk && "$size" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$system_disks" == *" $path "* ]] && continue
    if [[ "$rm" == 1 || "$tran" == usb || "$tran" == mmc || "$path" == /dev/mmcblk* ]]; then
      echo "$path"
    fi
  done
}
