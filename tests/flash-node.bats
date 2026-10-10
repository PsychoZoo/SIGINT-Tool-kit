#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for scripts/flash-node.sh's payload building (what goes on the card).

setup() {
  git config --global --add safe.directory '*'
  source "$BATS_TEST_DIRNAME/../scripts/flash-node.sh"
  out=$BATS_TEST_TMPDIR/payload
  name=node-1 programs=demo master=10.0.0.5:1884 node_password=$(printf 'a%.0s' {1..48})
  timezone=UTC ssh_key="" ssid="" wifi_password="" country=""
}

@test "pc payload with no SSH key and no Wi-Fi (Ethernet only) builds" {
  target=pc
  write_payload "$out"
  [ -f "$out/preseed.cfg" ]
  [ -f "$out/sigint/late.sh" ]
  [ -f "$out/sigint/node.env" ]
  [ ! -e "$out/sigint/authorized_keys" ]
  [ ! -e "$out/sigint/sigint-wifi.nmconnection" ]
}

@test "pc payload with key and Wi-Fi includes both" {
  target=pc ssh_key="ssh-ed25519 AAAAkey me" ssid="Home" wifi_password="password1" country=US
  write_payload "$out"
  [ "$(cat "$out/sigint/authorized_keys")" = "ssh-ed25519 AAAAkey me" ]
  grep -q '^ssid=Home$' "$out/sigint/sigint-wifi.nmconnection"
}

@test "pi payload builds without key or Wi-Fi" {
  target=pi
  write_payload "$out"
  [ -f "$out/user-data" ] && [ -f "$out/network-config" ] && [ -f "$out/meta-data" ]
  [ -f "$out/sigint/sigint-firstboot.sh" ]
}

@test "the bundled toolkit has no secrets" {
  target=pi
  write_payload "$out"
  run ! bash -c "tar -tzf '$out/sigint/toolkit.tar.gz' | grep -E '(^|/)\\.env($|\\.[^e])|\\.pem$|\\.key$|broker/auth/|^images/'"
  tar -tzf "$out/sigint/toolkit.tar.gz" | grep -qx toolkit.sh
}

@test "bundle_excluded: secrets out, the template in" {
  bundle_excluded .env
  bundle_excluded .env.bak
  bundle_excluded modules/x/.env
  bundle_excluded certs/server.key
  bundle_excluded broker/auth/passwd
  run ! bundle_excluded .env.example
  run ! bundle_excluded toolkit.sh
}
