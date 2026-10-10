"""Helpers for the central PostgreSQL database."""

import logging
import time

import psycopg
from psycopg.types.json import Jsonb

from .config import DATABASE_URL

log = logging.getLogger(__name__)


def connect(url: str = DATABASE_URL, retries: int = 30, delay: float = 2.0) -> psycopg.Connection:
    """Open an autocommit connection, waiting for the database to come up."""
    for attempt in range(1, retries + 1):
        try:
            return psycopg.connect(url, autocommit=True)
        except psycopg.OperationalError as exc:
            if attempt == retries:
                raise
            log.warning("database not ready (%s), retrying in %.0fs", exc, delay)
            time.sleep(delay)
    raise RuntimeError("unreachable")


def kv_get(conn: psycopg.Connection, namespace: str, key: str, default=None):
    row = conn.execute(
        "SELECT value FROM kv WHERE namespace = %s AND key = %s", (namespace, key)
    ).fetchone()
    return row[0] if row else default


def kv_set(conn: psycopg.Connection, namespace: str, key: str, value) -> None:
    conn.execute(
        """INSERT INTO kv (namespace, key, value) VALUES (%s, %s, %s)
           ON CONFLICT (namespace, key)
           DO UPDATE SET value = EXCLUDED.value, updated_at = now()""",
        (namespace, key, Jsonb(value)),
    )
