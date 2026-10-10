# Image builder for ./toolkit.sh flash-node: the tools to customise official
# Raspberry Pi OS and Debian images, so the master needs nothing extra installed.
FROM debian:13-slim AS builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl fdisk mtools openssl xorriso xz-utils \
 && rm -rf /var/lib/apt/lists/*
COPY build-image.sh /usr/local/bin/build-image.sh
ENTRYPOINT ["bash", "/usr/local/bin/build-image.sh"]

# Test runner for ./toolkit.sh test: bats, shellcheck, YAML parsing, and the
# tools to make small fixture disk images.
FROM builder AS test
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats dosfstools git python3 python3-yaml shellcheck \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT []
