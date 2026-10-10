#!/bin/sh
# Builds the Mosquitto config for this device's role, then starts Mosquitto.
#
# ROLE=master  Every client logs in. This device's own programs use the internal
#              account (MQTT_USERNAME / MQTT_PASSWORD); each node has its own
#              account (./toolkit.sh add-node) and connects on port 1884, which
#              is the only port meant to be exposed beyond this machine.
# ROLE=node    An open broker for this device's own programs (only reachable
#              locally), plus a bridge to the master. Everything published on
#              sigint/# is forwarded to the master; commands for this node (and
#              NODE_IMPORT_TOPICS) come back. While the link is down, messages are
#              queued on disk and delivered with their original timestamps when it
#              returns.
set -eu

ROLE=${ROLE:-master}
NODE_NAME=${NODE_NAME:-master}
CONF_DIR=${BROKER_CONF_DIR:-/tmp/mosquitto}
DATA_DIR=${BROKER_DATA_DIR:-/mosquitto/data}
AUTH_DIR=${BROKER_AUTH_DIR:-/mosquitto/auth}
LOCAL_PORT=${BROKER_LOCAL_PORT:-1883}
WS_PORT=${BROKER_WS_PORT-9001}  # empty = no WebSocket listener
NODE_LISTEN_PORT=${BROKER_NODE_PORT:-1884}
CONF="$CONF_DIR/mosquitto.conf"

mkdir -p "$CONF_DIR" "$DATA_DIR"
# What the image's own entrypoint would do: Mosquitto runs as 'mosquitto'.
chown -R mosquitto "$DATA_DIR" 2>/dev/null || true

# Note: per_listener_settings is deliberately not used. In Mosquitto 2.0 it
# stops messages being queued for clients that are briefly disconnected.
cat > "$CONF" <<EOF
persistence true
persistence_location $DATA_DIR/
autosave_interval 60
log_dest stdout
${BROKER_RUN_AS:+user $BROKER_RUN_AS}
# Room to buffer data while a node's link is down (or a client is restarting).
max_queued_messages ${BROKER_MAX_QUEUED:-200000}

listener $LOCAL_PORT
EOF

if [ -n "$WS_PORT" ]; then
  printf 'listener %s\nprotocol websockets\n' "$WS_PORT" >> "$CONF"
fi

case "$ROLE" in
  master)
    : "${MQTT_USERNAME:?set MQTT_USERNAME (internal account for this device's programs)}"
    : "${MQTT_PASSWORD:?set MQTT_PASSWORD}"
    PASSWD="$AUTH_DIR/passwd"
    mkdir -p "$AUTH_DIR"
    touch "$PASSWD"
    chmod 0700 "$PASSWD"
    "${MOSQUITTO_PASSWD_BIN:-mosquitto_passwd}" -b "$PASSWD" "$MQTT_USERNAME" "$MQTT_PASSWORD"
    # Mosquitto drops root privileges to the 'mosquitto' user before reading it.
    chown mosquitto "$PASSWD" 2>/dev/null || true

    # The internal account can do anything. Each node may publish only under
    # sigint/<its name>/, read everything, and send commands to any module.
    cat > "$CONF_DIR/acl" <<EOF
user $MQTT_USERNAME
topic readwrite #

pattern readwrite sigint/%u/#
pattern read sigint/#
pattern write sigint/+/+/cmd/#
EOF
    cat >> "$CONF" <<EOF

# Nodes connect here, directly over the LAN or through a Cloudflare Tunnel.
listener $NODE_LISTEN_PORT

allow_anonymous false
password_file $PASSWD
acl_file $CONF_DIR/acl
EOF
    ;;

  node)
    : "${MASTER_ADDRESS:?set MASTER_ADDRESS (host:port of the master, or master-link:1884 via Cloudflare)}"
    : "${NODE_PASSWORD:?set NODE_PASSWORD (from ./toolkit.sh add-node on the master)}"
    cat >> "$CONF" <<EOF
allow_anonymous true

# Link to the master.
connection master
address $MASTER_ADDRESS
bridge_protocol_version mqttv50
remote_clientid sigint-node-$NODE_NAME
remote_username $NODE_NAME
remote_password $NODE_PASSWORD
cleansession false
restart_timeout 2 30
keepalive_interval 30
notifications true
notification_topic sigint/$NODE_NAME/node/status
topic sigint/# out 1
topic sigint/$NODE_NAME/+/cmd/# in 1
EOF
    # Extra topics to receive from the master (other nodes' data, alerts...).
    for topic in ${NODE_IMPORT_TOPICS:-}; do
      echo "topic $topic in 1" >> "$CONF"
    done
    ;;

  *)
    echo "ROLE must be 'master' or 'node', got '$ROLE'" >&2
    exit 1
    ;;
esac

echo "Starting broker as $ROLE (node name: $NODE_NAME)"
exec "${MOSQUITTO_BIN:-mosquitto}" -c "$CONF"
