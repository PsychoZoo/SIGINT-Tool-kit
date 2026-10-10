#!/bin/sh
# Runs inside the Debian installer (preseed/late_command) after the system is
# installed to /target. Copies the node settings in and sets up first boot:
# sigint-firstboot.service installs Docker and joins the master.
set -e

src=/cdrom/sigint
target=/target
user=sigint
prov=$target/opt/sigint-provision

mkdir -p "$prov"
cp -r "$src/." "$prov/"
# Lets pick-disk.sh recognise this disk if the installer drive is booted again:
# a marker file, and a label on the root filesystem (readable without mounting).
date -u > "$target/etc/sigint-node"
rootdev=""
while read -r dev mnt _; do
  if [ "$mnt" = "$target" ]; then rootdev=$dev; fi
done < /proc/mounts
if [ -n "$rootdev" ]; then
  in-target e2label "$rootdev" sigint-node || logger -t sigint "could not label $rootdev"
fi
chmod 700 "$prov"
chmod 600 "$prov/node.env"

cp "$prov/sigint-firstboot.service" "$target/etc/systemd/system/"
in-target systemctl enable sigint-firstboot.service

# Key-only SSH, passwordless sudo, no usable password.
# (Only busybox applets here: no install(1), no awk.)
if [ -s "$src/authorized_keys" ]; then
  mkdir -p "$target/home/$user/.ssh"
  cp "$src/authorized_keys" "$target/home/$user/.ssh/authorized_keys"
  chmod 700 "$target/home/$user/.ssh"
  chmod 600 "$target/home/$user/.ssh/authorized_keys"
  in-target chown -R "$user:$user" "/home/$user/.ssh"
fi
echo "$user ALL=(ALL) NOPASSWD:ALL" > "$target/etc/sudoers.d/$user"
chmod 440 "$target/etc/sudoers.d/$user"
in-target passwd -l "$user"
mkdir -p "$target/etc/ssh/sshd_config.d"
echo "PasswordAuthentication no" > "$target/etc/ssh/sshd_config.d/sigint.conf"

# Wi-Fi for the installed system, and let NetworkManager manage every interface
# (the installer configured the install-time network with ifupdown).
if [ -f "$src/sigint-wifi.nmconnection" ]; then
  wifi=$target/etc/NetworkManager/system-connections/sigint-wifi.nmconnection
  mkdir -p "${wifi%/*}"
  cp "$src/sigint-wifi.nmconnection" "$wifi"
  chmod 600 "$wifi"
fi
printf 'auto lo\niface lo inet loopback\n' > "$target/etc/network/interfaces"
