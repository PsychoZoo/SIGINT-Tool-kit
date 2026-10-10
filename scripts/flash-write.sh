# shellcheck shell=bash
# Writing an image to an SD card or USB drive, safely. Sourced by
# scripts/flash-node.sh (needs provision/lib.sh's filter_flash_disks).
#
# Only removable / USB / SD-card disks are offered, never one this system is
# using, the device name must be typed back, and the disk's identity is checked
# again right before writing.

# Disks in use by this system: anything with a filesystem mounted outside the
# desktop's removable-media folders (/run/media, /media), and active swap,
# walking up through partitions, LUKS and LVM. This also catches the stick a
# live system runs from.
system_disks() {
  {
    findmnt -rn -o SOURCE,TARGET 2>/dev/null | while read -r src mountpoint; do
      case "$mountpoint" in /run/media/*|/media/*) continue ;; esac
      src=${src%%\[*}
      if [[ -b "$src" ]]; then echo "$src"; fi
    done
    swapon --show=NAME --noheadings 2>/dev/null
  } | sort -u | while read -r src; do
    lsblk -nspo PATH,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'
  done | sort -u | tr '\n' ' '
}

flashable_disks() {
  lsblk -dnbP -o PATH,SIZE,TYPE,RM,HOTPLUG,TRAN,MODEL | filter_flash_disks "$(system_disks)"
}

describe_disk() {
  lsblk -dno PATH,SIZE,TRAN,MODEL "$1" | tr -s ' '
}

# What's on it, so a wrong pick is easy to spot.
describe_contents() {
  lsblk -no NAME,SIZE,FSTYPE,LABEL "$1" | tail -n +2 | sed 's/^/      /'
}

disk_identity() {  # size, model and serial: must not change between choosing and writing
  lsblk -dnbo SIZE,MODEL,SERIAL "$1" 2>/dev/null | tr -s ' '
}

is_flashable() {
  local d
  for d in $(flashable_disks); do
    if [[ "$d" == "$1" ]]; then return 0; fi
  done
  return 1
}

choose_disk() {  # choose_disk [preselected] -> prints the chosen device
  local disks=() i answer
  if [[ -n "$1" ]]; then
    is_flashable "$1" || die "$1 is not a removable or USB disk, or this system is using it"
    echo "$1"
    return
  fi
  mapfile -t disks < <(flashable_disks)
  while (( ${#disks[@]} == 0 )); do
    read -r -p "No SD card or USB drive found. Insert one and press Enter (Ctrl+C to stop) " _ || die "cancelled"
    mapfile -t disks < <(flashable_disks)
  done
  echo "Cards and drives found:" >&2
  for i in "${!disks[@]}"; do
    echo "  $((i + 1))) $(describe_disk "${disks[$i]}")" >&2
    describe_contents "${disks[$i]}" >&2
  done
  read -r -p "Write to which one? [1-${#disks[@]}]: " answer || die "cancelled"
  if [[ ! "$answer" =~ ^[0-9]+$ ]] || (( answer < 1 || answer > ${#disks[@]} )); then
    die "no such choice"
  fi
  echo "${disks[$((answer - 1))]}"
}

confirm_erase() {  # confirm_erase DEVICE
  local typed
  echo >&2
  echo "EVERYTHING on $(describe_disk "$1") will be erased:" >&2
  describe_contents "$1" >&2
  read -r -p "Type $1 to continue: " typed || die "cancelled"
  [[ "$typed" == "$1" ]] || die "not confirmed, nothing was written"
}

unmount_partitions() {  # unmount_partitions DEVICE
  local part mnt
  while read -r part mnt; do
    if [[ -z "$mnt" ]]; then continue; fi
    if [[ "$mnt" == "[SWAP]" ]]; then
      sudo swapoff "$part"
    else
      sudo umount "$part"
    fi
  done < <(lsblk -nlpo PATH,MOUNTPOINT "$1" | tail -n +2)
}

write_to_card() {  # write_to_card IMAGE [DEVICE]
  local image=$1 dev identity
  echo "Writing a disk needs root; sudo may ask for your password now."
  sudo -v
  dev=$(choose_disk "${2:-}")
  identity=$(disk_identity "$dev")
  confirm_erase "$dev"
  unmount_partitions "$dev"
  if ! is_flashable "$dev" || [[ "$(disk_identity "$dev")" != "$identity" ]]; then
    die "$dev changed since it was chosen (card swapped?); nothing was written"
  fi
  echo "Writing $(basename "$image") to $dev..."
  sudo dd if="$image" of="$dev" bs=4M conv=fsync oflag=direct status=progress
  sync
  sudo eject "$dev" 2>/dev/null || true
  echo "Written. You can remove $dev."
}
