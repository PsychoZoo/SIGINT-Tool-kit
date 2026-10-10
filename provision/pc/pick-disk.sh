#!/bin/sh
# Runs inside the Debian installer (partman/early_command), before partitioning.
# Picks the disk to install to, and refuses (the installer stops with an error,
# nothing is erased) unless the choice is unambiguous:
#   - never the USB drive the installer runs from, nor any other USB disk
#   - exactly one internal disk must be present
#   - that disk must not already hold a SIGINT node (stops a reinstall loop if
#     the PC is turned back on with the installer drive still plugged in)
set -e

fail() {
  logger -t sigint "$*"
  # The installer then shows an error with "Continue" as the default. Make sure
  # continuing can't erase anything: refuse partman's "write changes?" questions.
  debconf-set partman/confirm false || true
  debconf-set partman/confirm_nooverwrite false || true
  debconf-set partman-partitioning/confirm_write_new_label false || true
  echo "SIGINT node install stopped: $*" > /dev/console 2>/dev/null || true
  exit 1
}

media=""
while read -r dev mnt _; do
  if [ "$mnt" = /cdrom ]; then media=$dev; break; fi
done < /proc/mounts
[ -n "$media" ] || fail "can't tell which drive the installer runs from"
media_disk=$media
if [ ! -e "/sys/block/${media##*/}" ]; then
  # A partition (sdb1, mmcblk0p1): strip the partition number.
  media_disk=$(echo "$media" | sed 's/p\{0,1\}[0-9][0-9]*$//')
fi

candidates=""
for disk in $(list-devices disk); do
  [ "$disk" = "$media_disk" ] && continue
  case "$(readlink -f "/sys/block/${disk##*/}")" in
    */usb*) continue ;;  # USB drives: backups, other sticks
  esac
  [ "$(cat "/sys/block/${disk##*/}/removable" 2>/dev/null || echo 0)" = 1 ] && continue
  candidates="$candidates $disk"
done
# shellcheck disable=SC2086  # split the space-separated list on purpose
set -- $candidates
[ $# -eq 0 ] && fail "no internal disk found to install to"
[ $# -gt 1 ] && fail "this PC has several internal disks ($*); disconnect all but the one to erase, or install by hand"
target=$1

# Already a SIGINT node? Then this is the installer drive left plugged in.
# late.sh labels the node's root filesystem; blkid reads labels without mounting.
# As a fallback, look for the marker file (filesystem drivers may not be loaded
# yet this early, so load ext4 and name the type).
SIGINT_LABEL=sigint-node
modprobe ext4 2>/dev/null || true
mkdir -p /tmp/sigint-check
for part in "$target"?*; do
  [ -b "$part" ] || continue
  if [ "$(blkid -o value -s LABEL "$part" 2>/dev/null)" = "$SIGINT_LABEL" ]; then
    fail "$target already holds a SIGINT node; remove the installer drive and restart"
  fi
  if mount -t ext4 -o ro "$part" /tmp/sigint-check 2>/dev/null; then
    found=0
    if [ -f /tmp/sigint-check/etc/sigint-node ]; then found=1; fi
    umount /tmp/sigint-check
    if [ "$found" = 1 ]; then
      fail "$target already holds a SIGINT node; remove the installer drive and restart"
    fi
  fi
done

logger -t sigint "installing to $target (installer media: $media)"
debconf-set partman-auto/disk "$target"
debconf-set grub-installer/bootdev "$target"
