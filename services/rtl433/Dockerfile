# rtl_433: decodes 433/868/915 MHz ISM-band devices (weather stations, sensors,
# remotes, TPMS...) from an RTL-SDR dongle and publishes them straight onto the
# bus with its built-in MQTT output, on sigint/<node>/rtl433/data/ism.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends rtl-433 \
 && rm -rf /var/lib/apt/lists/*
ENV MQTT_HOST=broker MQTT_PORT=1883 MQTT_USERNAME=local MQTT_PASSWORD="" NODE_NAME=master RTL433_SDR_SERIAL="" RTL433_ARGS=""
# -d :SERIAL picks the dongle by serial number; omitted, the first dongle is used.
CMD ["sh", "-c", "exec rtl_433 ${RTL433_SDR_SERIAL:+-d :$RTL433_SDR_SERIAL} -M time:iso -M level -F \"mqtt://${MQTT_HOST}:${MQTT_PORT},user=${MQTT_USERNAME},pass=${MQTT_PASSWORD},retain=0,events=sigint/${NODE_NAME}/rtl433/data/ism\" ${RTL433_ARGS}"]
