"""Connection settings, read from the environment that docker-compose provides."""

import os

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://sigint:sigint@localhost:5432/sigint"
)
MQTT_HOST = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USERNAME = os.environ.get("MQTT_USERNAME") or None
MQTT_PASSWORD = os.environ.get("MQTT_PASSWORD") or None
TOPIC_ROOT = os.environ.get("SIGINT_TOPIC_ROOT", "sigint")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
