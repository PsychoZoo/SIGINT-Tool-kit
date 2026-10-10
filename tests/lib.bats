#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Unit tests for provision/lib.sh. Run with: ./toolkit.sh test

setup() {
  source "$BATS_TEST_DIRNAME/../provision/lib.sh"
}

yaml_ok() {  # parses stdin as YAML, prints it back as JSON
  python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(sys.stdin)))'
}

# --- validation -----------------------------------------------------------------

@test "node names: accepts lowercase names, rejects others" {
  valid_node_name pi-1
  valid_node_name roof_pi2
  run ! valid_node_name ""
  run ! valid_node_name Pi
  run ! valid_node_name -pi
  run ! valid_node_name "pi 1"
  run ! valid_node_name 'pi;rm'
  run ! valid_node_name "$(printf 'a%.0s' {1..33})"
}

@test "programs: node programs only, never lora or all" {
  valid_programs ""
  valid_programs "demo"
  valid_programs "adsb ais kismet"
  run ! valid_programs "lora"
  run ! valid_programs "adsb all"
  run ! valid_programs "nope"
}

@test "programs_need_sdr: true for SDR programs only" {
  programs_need_sdr "kismet adsb"
  programs_need_sdr "sdr"
  run ! programs_need_sdr "demo kismet"
  run ! programs_need_sdr ""
}

@test "country codes and targets" {
  valid_country US
  run ! valid_country us
  run ! valid_country USA
  valid_target pi
  valid_target pc
  run ! valid_target mac
}

@test "wifi password: 8-63 printable characters" {
  valid_wifi_password 'pass word"\x'
  run ! valid_wifi_password short
  run ! valid_wifi_password "$(printf 'a%.0s' {1..64})"
  run ! valid_wifi_password $'with\nnewline'
  run ! valid_wifi_password 'ends with backslash\'
}

@test "ssid: at most 32 bytes, one line" {
  valid_ssid "Home Net"
  valid_ssid "$(printf 'a%.0s' {1..32})"
  run ! valid_ssid "$(printf 'a%.0s' {1..33})"
  run ! valid_ssid "$(printf 'é%.0s' {1..17})"
  run ! valid_ssid $'two\nlines'
}

@test "ssh keys: accepts public keys, rejects junk and multi-line input" {
  valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample me@host"
  valid_ssh_pubkey "ssh-rsa AAAAB3NzaC1yc2E="
  run ! valid_ssh_pubkey "-----BEGIN OPENSSH PRIVATE KEY-----"
  run ! valid_ssh_pubkey $'ssh-ed25519 AAAA me\nssh-ed25519 BBBB other'
  run ! valid_ssh_pubkey ""
}

# --- Raspberry Pi cloud-init --------------------------------------------------------

@test "pi user-data: valid cloud-config with hostname, locked user and ssh key" {
  run render_pi_user_data pi-1 Europe/London "ssh-ed25519 AAAAkey me@host"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#cloud-config" ]
  json=$(echo "$output" | yaml_ok)
  [[ "$json" == *'"hostname": "pi-1"'* ]]
  [[ "$json" == *'"lock_passwd": true'* ]]
  [[ "$json" == *'"ssh_authorized_keys": ["ssh-ed25519 AAAAkey me@host"]'* ]]
  [[ "$json" == *'"ssh_pwauth": false'* ]]
  [[ "$json" == *'sigint-firstboot.service'* ]]
}

@test "pi user-data: no ssh key means no ssh server" {
  json=$(render_pi_user_data pi-1 UTC "" | yaml_ok)
  [[ "$json" != *ssh_authorized_keys* ]]
  [[ "$json" != *enable_ssh* ]]
}

@test "pi network-config: Wi-Fi with awkward characters survives YAML" {
  json=$(render_pi_network_config 'My "Net": #1\' 'p@ss: "w0rd" #\' GB | yaml_ok)
  python3 - "$json" <<'EOF'
import json, sys
net = json.loads(sys.argv[1])["network"]
ap = net["wifis"]["wlan0"]["access-points"]
assert list(ap) == ['My "Net": #1\\'], ap
assert ap['My "Net": #1\\']["password"] == 'p@ss: "w0rd" #\\'
assert net["wifis"]["wlan0"]["regulatory-domain"] == "GB"
assert net["ethernets"]["eth0"]["dhcp4"] is True
assert net["renderer"] == "NetworkManager"
assert "renderer" not in net["wifis"]
EOF
}

@test "pi network-config: no SSID means Ethernet only" {
  json=$(render_pi_network_config "" "" "" | yaml_ok)
  [[ "$json" != *wifis* ]]
  [[ "$json" == *'"renderer": "NetworkManager"'* ]]
  [[ "$json" == *eth0* ]]
}

@test "pi meta-data: instance id per node" {
  run render_pi_meta_data pi-1
  [[ "$output" == *"instance-id: sigint-pi-1"* ]]
}

# --- PC installer ---------------------------------------------------------------

@test "preseed: unattended, powers off, runs our hooks" {
  run render_preseed pc-1 America/New_York
  [[ "$output" == *"netcfg/hostname string pc-1"* ]]
  [[ "$output" == *"time/zone string America/New_York"* ]]
  [[ "$output" == *"partman/early_command string sh /cdrom/sigint/pick-disk.sh"* ]]
  [[ "$output" == *"preseed/late_command string sh /cdrom/sigint/late.sh"* ]]
  [[ "$output" == *"debian-installer/exit/poweroff boolean true"* ]]
  [[ "$output" == *"passwd/root-login boolean false"* ]]
  [[ "$output" != *wireless* ]]
}

@test "preseed: Wi-Fi details for the installer when given" {
  run render_preseed pc-1 UTC "Home Net" "secret pass"
  [[ "$output" == *"netcfg/wireless_essid string Home Net"* ]]
  [[ "$output" == *"netcfg/wireless_wpa string secret pass"* ]]
}

@test "boot menus start the automatic install" {
  run render_grub_entry pc-1
  [[ "$output" == *"preseed/file=/cdrom/preseed.cfg"* ]]
  [[ "$output" == *"set timeout=5"* ]]
  run render_isolinux pc-1
  [[ "$output" == *"default sigint"* ]]
  [[ "$output" == *"preseed/file=/cdrom/preseed.cfg"* ]]
}

@test "wifi keyfile escapes backslashes and edge spaces" {
  run render_wifi_keyfile ' my\net ' 'pass\word'
  [[ "$output" == *'ssid=\smy\\net\s'* ]]
  [[ "$output" == *'psk=pass\\word'* ]]
}

# --- node settings -------------------------------------------------------------------

@test "node.env round-trips hostile values safely" {
  tmp=$BATS_TEST_TMPDIR/node.env
  render_node_env pi-1 '10.0.0.5:1884' 'pa$s `id` "q"' 'adsb ism' 0 '' '' > "$tmp"
  ( source "$tmp"
    [ "$NODE_NAME" = pi-1 ]
    [ "$MASTER" = 10.0.0.5:1884 ]
    [ "$NODE_PASSWORD" = 'pa$s `id` "q"' ]
    [ "$PROGRAMS" = 'adsb ism' ]
    [ "$CLOUDFLARE" = 0 ] )
}

# --- disk selection -------------------------------------------------------------------

@test "flash disks: offers USB and SD cards, never system or internal disks" {
  run filter_flash_disks "/dev/nvme0n1" <<'EOF'
PATH="/dev/nvme0n1" SIZE="512110190592" TYPE="disk" RM="0" HOTPLUG="0" TRAN="nvme" MODEL="Samsung SSD"
PATH="/dev/sda" SIZE="2000398934016" TYPE="disk" RM="0" HOTPLUG="1" TRAN="sata" MODEL="Hot-swap bay HDD"
PATH="/dev/sdb" SIZE="31914983424" TYPE="disk" RM="1" HOTPLUG="1" TRAN="usb" MODEL="SD Reader"
PATH="/dev/sdc" SIZE="0" TYPE="disk" RM="1" HOTPLUG="1" TRAN="usb" MODEL="Empty slot"
PATH="/dev/mmcblk0" SIZE="63864569856" TYPE="disk" RM="0" HOTPLUG="0" TRAN="" MODEL=""
PATH="/dev/sr0" SIZE="1073741312" TYPE="rom" RM="1" HOTPLUG="0" TRAN="sata" MODEL="DVD"
PATH="/dev/loop0" SIZE="4096" TYPE="loop" RM="0" HOTPLUG="0" TRAN="" MODEL=""
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'/dev/sdb\n/dev/mmcblk0' ]
}

@test "flash disks: a USB disk holding this system is never offered" {
  run filter_flash_disks "/dev/sda" <<'EOF'
PATH="/dev/sda" SIZE="256060514304" TYPE="disk" RM="0" HOTPLUG="1" TRAN="usb" MODEL="USB SSD"
EOF
  [ -z "$output" ]
}
