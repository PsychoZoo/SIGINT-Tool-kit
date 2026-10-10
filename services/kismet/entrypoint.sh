#!/bin/sh
# Writes kismet_site.conf from environment variables, then starts Kismet.
set -eu

: "${KISMET_USER:?set KISMET_USER}"
: "${KISMET_PASSWORD:?set KISMET_PASSWORD}"

{
  echo "httpd_username=${KISMET_USER}"
  echo "httpd_password=${KISMET_PASSWORD}"
  echo "httpd_bind_address=${KISMET_BIND_ADDRESS:-127.0.0.1}"
  echo "httpd_port=${KISMET_PORT:-2501}"
  echo "log_prefix=/data/"
  echo "log_types=kismet"
  # One capture source per space-separated entry, e.g. "wlan1 hci0"
  # or "wlan1:name=roof,channels=\"1,6,11\"".
  for source in ${KISMET_SOURCES:-}; do
    echo "source=${source}"
  done
} > /etc/kismet/kismet_site.conf

if [ -z "${KISMET_SOURCES:-}" ]; then
  echo "KISMET_SOURCES is empty: Kismet starts with no capture sources." >&2
  echo "Set it in .env (e.g. KISMET_SOURCES=wlan1) or add sources in the web UI." >&2
fi

cd /data
exec kismet --no-line-wrap "$@"
