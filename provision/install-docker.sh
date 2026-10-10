#!/usr/bin/env bash
# Installs Docker Engine and the Compose plugin, then starts Docker.
# Used by `./toolkit.sh setup` (via sudo) and by every node on first boot.
#
# Supported: Debian, Raspberry Pi OS (64-bit), Ubuntu and derivatives (Docker's
# official apt repository), Arch and derivatives (pacman).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "install-docker.sh must run as root" >&2
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release
family=" ${ID:-} ${ID_LIKE:-} "

install_apt() {  # install_apt debian|ubuntu codename
  local distro=$1 codename=$2
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distro
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

case "$family" in
  *" arch "*)
    # No -y: refreshing without upgrading would be a partial upgrade.
    pacman -S --needed --noconfirm docker docker-compose docker-buildx
    ;;
  *" ubuntu "*)
    install_apt ubuntu "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    ;;
  *" debian "*)
    install_apt debian "$VERSION_CODENAME"
    ;;
  *)
    echo "Don't know how to install Docker on '${PRETTY_NAME:-this system}'." >&2
    echo "Install Docker Engine with the Compose plugin (https://docs.docker.com/engine/install/), then run this again." >&2
    exit 1
    ;;
esac

systemctl enable --now docker
