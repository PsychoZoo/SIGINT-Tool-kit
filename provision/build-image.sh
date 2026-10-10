#!/usr/bin/env bash
# Builds a ready-to-flash node image from an official base image. Runs in the
# provision builder container (provision/Dockerfile); started by
# scripts/flash-node.sh.
#
#   build-image.sh pi PAYLOAD_DIR OUTPUT.img   Raspberry Pi OS Lite (arm64)
#   build-image.sh pc PAYLOAD_DIR OUTPUT.iso   Debian netinst (amd64), unattended
#
# PAYLOAD_DIR (rendered by flash-node.sh):
#   pi: user-data network-config meta-data sigint/
#   pc: preseed.cfg grub-entry.cfg isolinux.cfg sigint/
#
# Base images are downloaded once, checked against the publisher's SHA-256 sums
# and cached in $CACHE_DIR. Without internet, the newest cached base is used.
set -euo pipefail
umask 077

CACHE_DIR=${CACHE_DIR:-/images/cache}
PI_LATEST_URL=${PI_LATEST_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}
DEBIAN_ISO_DIR=${DEBIAN_ISO_DIR:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}
SECTOR=512
export MTOOLS_SKIP_CHECK=1

log() { echo "[build-image] $*" >&2; }
die() { echo "[build-image] error: $*" >&2; exit 1; }

# verified_download URL NAME SHA256 -> prints the cached file's path
verified_download() {
  local url=$1 name=$2 sum=$3 file=$CACHE_DIR/$2
  if [[ ! -f "$file" ]]; then
    log "downloading $name"
    curl -fL --proto =https --proto-redir =https --progress-bar -o "$file.part" "$url" \
      || die "downloading $name failed"
    mv "$file.part" "$file"
  fi
  log "verifying $name"
  if ! echo "$sum  $file" | sha256sum -c --quiet -; then
    rm -f "$file"
    die "$name does not match its published SHA-256 sum; deleted it, run again to re-download"
  fi
  echo "$sum" > "$file.sha256"
  echo "$file"
}

# newest_cached GLOB -> newest cached base whose sum was verified before
newest_cached() {
  local f newest=""
  for f in "$CACHE_DIR"/$1; do
    [[ -f "$f" && -f "$f.sha256" ]] || continue
    [[ -z "$newest" || "$f" -nt "$newest" ]] && newest=$f
  done
  [[ -n "$newest" ]] || return 1
  log "WARNING: can't reach the download site; using the cached $(basename "$newest")"
  log "         from $(date -r "$newest" +%F). It may be missing recent security updates."
  echo "$(cat "$newest.sha256")  $newest" | sha256sum -c --quiet - \
    || die "cached $(basename "$newest") is corrupt; delete it and run again with internet"
  echo "$newest"
}

pi_base() {
  local url name sum
  if url=$(curl -fsSLI --proto-redir =https -o /dev/null -w '%{url_effective}' "$PI_LATEST_URL") \
     && sum=$(curl -fsSL "$url.sha256" | awk '{print $1}') && [[ "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    name=${url##*/}
    [[ "$name" =~ ^[A-Za-z0-9._-]+\.img\.xz$ ]] || die "unexpected Raspberry Pi OS file name: $name"
    verified_download "$url" "$name" "$sum"
  else
    newest_cached '*raspios*arm64*lite.img.xz' || die "can't reach downloads.raspberrypi.com and no cached Raspberry Pi OS image"
  fi
}

pc_base() {
  local line name sum
  if line=$(curl -fsSL "$DEBIAN_ISO_DIR/SHA256SUMS" | grep -E '  debian-[0-9.]+-amd64-netinst\.iso$'); then
    sum=${line%% *}
    name=${line##* }
    verified_download "$DEBIAN_ISO_DIR/$name" "$name" "$sum"
  else
    newest_cached 'debian-*-amd64-netinst.iso' || die "can't reach cdimage.debian.org and no cached Debian installer"
  fi
}

# boot_partition_offset IMAGE -> byte offset of the first (FAT boot) partition
boot_partition_offset() {
  local start
  start=$(sfdisk -d "$1" | awk -F'[=,]' '/start=/ { gsub(/ /, "", $2); print $2; exit }')
  [[ "$start" =~ ^[0-9]+$ ]] || die "no partition table in $1"
  echo $((start * SECTOR))
}

build_pi() {
  local payload=$1 out=$2 base fat
  base=$(pi_base)
  log "unpacking $(basename "$base")"
  xz -T0 -dc "$base" > "$out.part"
  fat="$out.part@@$(boot_partition_offset "$out.part")"
  mdir -i "$fat" ::/config.txt >/dev/null || die "$(basename "$base") has no Raspberry Pi boot partition"
  log "adding node settings to the boot partition"
  mcopy -o -i "$fat" "$payload/user-data" "$payload/network-config" "$payload/meta-data" ::/
  mcopy -s -o -i "$fat" "$payload/sigint" ::/
  mv "$out.part" "$out"
}

iso_has() { xorriso -indev "$1" -find "$2" 2>/dev/null | grep -q .; }

build_pc() {
  local payload=$1 out=$2 base work hash
  base=$(pc_base)
  work=$(mktemp -d)
  log "remastering $(basename "$base")"
  hash=$(openssl passwd -6 "$(openssl rand -hex 24)")
  sed "s|@PASSWORD_HASH@|$hash|" "$payload/preseed.cfg" > "$work/preseed.cfg"
  local maps=(-map "$work/preseed.cfg" /preseed.cfg -map "$payload/sigint" /sigint)
  if iso_has "$base" /boot/grub/grub.cfg; then
    xorriso -osirrox on -indev "$base" -extract /boot/grub/grub.cfg "$work/grub.cfg" 2>/dev/null
    cat "$payload/grub-entry.cfg" "$work/grub.cfg" > "$work/grub.new"
    maps+=(-map "$work/grub.new" /boot/grub/grub.cfg)
  fi
  if iso_has "$base" /isolinux/isolinux.cfg; then
    maps+=(-map "$payload/isolinux.cfg" /isolinux/isolinux.cfg)
  fi
  rm -f "$out.part"
  xorriso -indev "$base" -outdev "$out.part" "${maps[@]}" -boot_image any replay 2>&1 \
    | grep -E 'FAILURE|SORRY|WARNING' >&2 || true
  rm -rf "$work"
  [[ -s "$out.part" ]] || die "xorriso did not write $out"
  mv "$out.part" "$out"
}

main() {
  [[ $# -eq 3 ]] || die "usage: build-image.sh pi|pc PAYLOAD_DIR OUTPUT"
  local target=$1 payload=$2
  OUT=$3
  # A failed build leaves no multi-GB half-written image behind.
  trap 'rm -f "$OUT.part"' EXIT
  local out=$OUT
  [[ -d "$payload/sigint" ]] || die "$payload has no sigint/ folder"
  mkdir -p "$CACHE_DIR"
  case "$target" in
    pi) build_pi "$payload" "$out" ;;
    pc) build_pc "$payload" "$out" ;;
    *)  die "unknown target '$target' (expected pi or pc)" ;;
  esac
  log "wrote $out"
}

main "$@"
