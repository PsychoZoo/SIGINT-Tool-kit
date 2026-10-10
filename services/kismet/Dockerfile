# Kismet wireless monitor (Wi-Fi, Bluetooth, and more), from the official
# Kismet package repository: https://www.kismetwireless.net/packages/
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget gnupg \
 && wget -qO - https://www.kismetwireless.net/repos/kismet-release.gpg.key \
    | gpg --dearmor > /usr/share/keyrings/kismet-archive-keyring.gpg \
 && echo 'deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/bookworm bookworm main' \
    > /etc/apt/sources.list.d/kismet.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
    kismet-core kismet-capture-linux-wifi kismet-capture-linux-bluetooth \
    iw wireless-tools iproute2 \
 && apt-get purge -y wget gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
VOLUME /data
ENTRYPOINT ["/entrypoint.sh"]
