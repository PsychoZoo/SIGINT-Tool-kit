# rtl_433: decodes 433/868/915 MHz ISM-band devices (weather stations, sensors,
# remotes, TPMS...) from an RTL-SDR dongle and publishes them straight onto the
# bus with its built-in MQTT output, on sigint/rtl433/data/ism.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends rtl-433 \
 && rm -rf /var/lib/apt/lists/*
ENV MQTT_HOST=broker MQTT_PORT=1883 RTL433_ARGS=""
CMD ["sh", "-c", "exec rtl_433 -M time:iso -M level -F \"mqtt://${MQTT_HOST}:${MQTT_PORT},retain=0,events=sigint/rtl433/data/ism\" -F kv ${RTL433_ARGS}"]
