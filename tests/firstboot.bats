#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for provision/firstboot/sigint-firstboot.sh with the system commands it
# calls (curl, docker, usermod, ...) replaced by stubs that record their calls.

FIRSTBOOT="$BATS_TEST_DIRNAME/../provision/firstboot/sigint-firstboot.sh"

setup() {
  t=$BATS_TEST_TMPDIR
  export SIGINT_PROVISION_DIR=$t/prov SIGINT_APP_DIR=$t/app SIGINT_DONE_FILE=$t/state/provisioned
  export SIGINT_LOG_FILE=$t/firstboot.log CALLS=$t/calls SIGINT_MODPROBE_CONF=$t/blacklist.conf
  mkdir -p "$t/prov" "$t/bin" "$t/bundle"

  for cmd in curl docker usermod chown modprobe id; do
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$cmd" > "$t/bin/$cmd"
    chmod +x "$t/bin/$cmd"
  done
  export PATH=$t/bin:$PATH

  # The bundled toolkit: a toolkit.sh that records how it was called.
  printf '#!/bin/sh\necho "toolkit $* [pw=$SIGINT_JOIN_PASSWORD cf=$SIGINT_JOIN_CF_SECRET]" >> "$CALLS"\ntouch .env\n' > "$t/bundle/toolkit.sh"
  chmod +x "$t/bundle/toolkit.sh"
  tar -czf "$t/prov/toolkit.tar.gz" -C "$t/bundle" .
  cp "$BATS_TEST_DIRNAME/../provision/lib.sh" "$t/prov/"
}

node_env() {  # node_env PROGRAMS CLOUDFLARE
  ( source "$BATS_TEST_DIRNAME/../provision/lib.sh"
    render_node_env pi-1 10.0.0.5:1884 'secret pw' "$1" "$2" cf-id cf-secret ) > "$SIGINT_PROVISION_DIR/node.env"
}

@test "joins the master, starts the programs, marks itself done" {
  node_env "demo kismet" 0
  run bash "$FIRSTBOOT"
  [ "$status" -eq 0 ]
  grep -qx "toolkit join --name pi-1 --master 10.0.0.5:1884 \\[pw=secret pw cf=cf-secret\\]" "$CALLS"
  grep -q "^toolkit up demo kismet " "$CALLS"
  [ -f "$SIGINT_DONE_FILE" ]
  [ ! -e "$SIGINT_PROVISION_DIR/node.env" ]
  run ! grep -q modprobe "$CALLS"
}

@test "Cloudflare nodes join through the tunnel with the service token" {
  node_env "adsb" 1
  run bash "$FIRSTBOOT"
  [ "$status" -eq 0 ]
  grep -qx "toolkit join --name pi-1 --master 10.0.0.5:1884 --cloudflare --cf-client-id cf-id \\[pw=secret pw cf=cf-secret\\]" "$CALLS"
  run ! grep -q -- "--password" "$CALLS"
}

@test "SDR programs get the DVB-T driver out of the way" {
  node_env "adsb" 0
  run bash "$FIRSTBOOT"
  grep -q "modprobe -r dvb_usb_rtl28xxu" "$CALLS"
}

@test "does nothing once provisioned" {
  node_env "demo" 0
  mkdir -p "$(dirname "$SIGINT_DONE_FILE")" && touch "$SIGINT_DONE_FILE"
  run bash "$FIRSTBOOT"
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}
