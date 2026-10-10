#!/usr/bin/env bats
# Integration tests for provision/build-image.sh, using small fixture images
# instead of the real downloads (base URLs point nowhere, so the cached
# fixtures are used). Run with: ./toolkit.sh test

BUILD="$BATS_TEST_DIRNAME/../provision/build-image.sh"

setup() {
  export CACHE_DIR=$BATS_TEST_TMPDIR/cache
  export PI_LATEST_URL=http://127.0.0.1:9/none DEBIAN_ISO_DIR=http://127.0.0.1:9/none
  export MTOOLS_SKIP_CHECK=1
  mkdir -p "$CACHE_DIR" "$BATS_TEST_TMPDIR/payload/sigint"
  echo "NODE_NAME=pi-1" > "$BATS_TEST_TMPDIR/payload/sigint/node.env"
  echo "firstboot" > "$BATS_TEST_TMPDIR/payload/sigint/sigint-firstboot.sh"
}

cache_with_sum() {  # cache_with_sum FILE: mark a fixture as a verified cached base
  sha256sum "$1" | awk '{print $1}' > "$1.sha256"
}

make_pi_fixture() {
  local t=$BATS_TEST_TMPDIR img=$BATS_TEST_TMPDIR/pi.img
  truncate -s 48M "$img"
  printf 'label: dos\nstart=8192, size=65536, type=c\nstart=73728, type=83\n' | sfdisk -q "$img"
  mkfs.vfat -C "$t/fat.img" 32768 >/dev/null
  echo "arm_64bit=1" > "$t/config.txt"
  mcopy -i "$t/fat.img" "$t/config.txt" ::/
  dd if="$t/fat.img" of="$img" bs=512 seek=8192 conv=notrunc status=none
  xz -T0 -c "$img" > "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img.xz"
  cache_with_sum "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img.xz"
}

make_pc_fixture() {
  local root=$BATS_TEST_TMPDIR/iso-root
  mkdir -p "$root/boot/grub" "$root/isolinux" "$root/install.amd"
  echo 'menuentry "Install" { linux /install.amd/vmlinuz }' > "$root/boot/grub/grub.cfg"
  echo 'default vesamenu.c32' > "$root/isolinux/isolinux.cfg"
  echo kernel > "$root/install.amd/vmlinuz"
  xorriso -as mkisofs -quiet -R -J -V DEBIAN -o "$CACHE_DIR/debian-13.0.0-amd64-netinst.iso" "$root"
  cache_with_sum "$CACHE_DIR/debian-13.0.0-amd64-netinst.iso"
}

@test "pi: settings land on the boot partition, the rest is untouched" {
  make_pi_fixture
  p=$BATS_TEST_TMPDIR/payload
  printf '#cloud-config\nhostname: pi-1\n' > "$p/user-data"
  echo "network: {version: 2}" > "$p/network-config"
  echo "instance-id: sigint-pi-1" > "$p/meta-data"

  run bash "$BUILD" pi "$p" "$BATS_TEST_TMPDIR/out.img"
  [ "$status" -eq 0 ]

  fat="$BATS_TEST_TMPDIR/out.img@@$((8192 * 512))"
  [ "$(mtype -i "$fat" ::/user-data)" = $'#cloud-config\nhostname: pi-1' ]
  [ "$(mtype -i "$fat" ::/meta-data)" = "instance-id: sigint-pi-1" ]
  [ "$(mtype -i "$fat" ::/sigint/node.env)" = "NODE_NAME=pi-1" ]
  [ "$(mtype -i "$fat" ::/config.txt)" = "arm_64bit=1" ]
  [ ! -e "$BATS_TEST_TMPDIR/out.img.part" ]
}

@test "pi: refuses an image without a Raspberry Pi boot partition" {
  truncate -s 8M "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img"
  printf 'label: dos\nstart=2048, type=c\n' | sfdisk -q "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img"
  xz -c "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img" > "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img.xz"
  rm "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img"
  cache_with_sum "$CACHE_DIR/2026-01-01-raspios-trixie-arm64-lite.img.xz"
  touch "$BATS_TEST_TMPDIR/payload/user-data" "$BATS_TEST_TMPDIR/payload/network-config" "$BATS_TEST_TMPDIR/payload/meta-data"

  run bash "$BUILD" pi "$BATS_TEST_TMPDIR/payload" "$BATS_TEST_TMPDIR/out.img"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/out.img" ]
}

@test "pc: preseed, payload and automatic boot entries are added to the ISO" {
  make_pc_fixture
  p=$BATS_TEST_TMPDIR/payload
  echo 'd-i passwd/user-password-crypted password @PASSWORD_HASH@' > "$p/preseed.cfg"
  echo '# SIGINT entry' > "$p/grub-entry.cfg"
  echo 'default sigint' > "$p/isolinux.cfg"

  run bash "$BUILD" pc "$p" "$BATS_TEST_TMPDIR/out.iso"
  [ "$status" -eq 0 ]

  x=$BATS_TEST_TMPDIR/x
  xorriso -osirrox on -indev "$BATS_TEST_TMPDIR/out.iso" -extract / "$x" 2>/dev/null
  [[ "$(cat "$x/preseed.cfg")" =~ password\ \$6\$ ]]
  [ "$(cat "$x/sigint/node.env")" = "NODE_NAME=pi-1" ]
  [ "$(head -n1 "$x/boot/grub/grub.cfg")" = "# SIGINT entry" ]
  grep -q 'menuentry "Install"' "$x/boot/grub/grub.cfg"
  [ "$(cat "$x/isolinux/isolinux.cfg")" = "default sigint" ]
}

@test "a base whose checksum doesn't match the published sum is rejected and deleted" {
  export DEBIAN_ISO_DIR=file://$BATS_TEST_TMPDIR/mirror
  mkdir -p "$BATS_TEST_TMPDIR/mirror"
  echo "tampered" > "$CACHE_DIR/debian-13.0.0-amd64-netinst.iso"
  echo "0000000000000000000000000000000000000000000000000000000000000000  debian-13.0.0-amd64-netinst.iso" \
    > "$BATS_TEST_TMPDIR/mirror/SHA256SUMS"

  run bash "$BUILD" pc "$BATS_TEST_TMPDIR/payload" "$BATS_TEST_TMPDIR/out.iso"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
  [ ! -e "$CACHE_DIR/debian-13.0.0-amd64-netinst.iso" ]
}

@test "unknown target is refused" {
  run bash "$BUILD" mac "$BATS_TEST_TMPDIR/payload" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown target"* ]]
}
