"""REST + WebSocket API and web dashboard for the central database and bus."""

import asyncio
import contextlib
import json
import logging
from datetime import datetime
from typing import Any

import paho.mqtt.client as mqtt
import psycopg
from fastapi import Body, FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from paho.mqtt.enums import CallbackAPIVersion
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool
from pydantic import BaseModel

from sigint_common import cmd_topic, data_topic
from sigint_common.config import DATABASE_URL, MQTT_HOST, MQTT_PASSWORD, MQTT_PORT, MQTT_USERNAME

log = logging.getLogger("api")

pool = AsyncConnectionPool(DATABASE_URL, open=False, kwargs={"autocommit": True, "row_factory": dict_row})
bus = mqtt.Client(CallbackAPIVersion.VERSION2, client_id="api")
live_clients: set[asyncio.Queue] = set()


async def listen_for_events() -> None:
    """Relay Postgres NOTIFYs from the events trigger to WebSocket clients."""
    while True:
        try:
            async with await psycopg.AsyncConnection.connect(DATABASE_URL, autocommit=True) as conn:
                await conn.execute("LISTEN sigint_events")
                async for note in conn.notifies():
                    event = json.loads(note.payload)
                    for queue in list(live_clients):
                        if queue.full():
                            queue.get_nowait()  # drop the oldest for slow clients
                        queue.put_nowait(event)
        except psycopg.OperationalError as exc:
            log.warning("live listener lost database (%s), retrying", exc)
            await asyncio.sleep(2)


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    await pool.open(wait=True, timeout=120)
    if MQTT_USERNAME:
        bus.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    bus.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
    bus.loop_start()
    listener = asyncio.create_task(listen_for_events())
    yield
    listener.cancel()
    bus.disconnect()
    bus.loop_stop()
    await pool.close()


app = FastAPI(title="SIGINT Tool-kit API", lifespan=lifespan)


async def query(sql: str, params: Any = None) -> list[dict]:
    async with pool.connection() as conn:
        cur = await conn.execute(sql, params)
        return await cur.fetchall()


def publish(topic: str, data: Any) -> None:
    if not bus.is_connected():
        raise HTTPException(503, "message bus unavailable")
    bus.publish(topic, json.dumps(data, default=str), qos=1)


# -- read ------------------------------------------------------------------

@app.get("/api/health")
async def health():
    await query("SELECT 1")
    return {"database": "ok", "bus": "ok" if bus.is_connected() else "down"}


@app.get("/api/modules")
async def list_modules():
    return await query("SELECT * FROM modules ORDER BY name")


@app.get("/api/events")
async def list_events(
    module: str | None = None,
    kind: str | None = None,
    since: datetime | None = None,
    after_id: int | None = None,
    contains: str | None = Query(None, description='JSON the event data must contain, e.g. {"icao":"a1b2c3"}'),
    limit: int = Query(100, ge=1, le=1000),
):
    where, params = [], {}
    if module:
        where.append("module = %(module)s")
        params["module"] = module
    if kind:
        where.append("kind = %(kind)s")
        params["kind"] = kind
    if since:
        where.append("ts >= %(since)s")
        params["since"] = since
    if after_id is not None:
        where.append("id > %(after_id)s")
        params["after_id"] = after_id
    if contains:
        try:
            params["contains"] = Jsonb(json.loads(contains))
        except ValueError:
            raise HTTPException(400, "contains must be valid JSON")
        where.append("data @> %(contains)s")
    params["limit"] = limit
    sql = "SELECT * FROM events"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY id DESC LIMIT %(limit)s"
    return await query(sql, params)


@app.get("/api/events/{event_id}")
async def get_event(event_id: int):
    rows = await query("SELECT * FROM events WHERE id = %s", (event_id,))
    if not rows:
        raise HTTPException(404, "event not found")
    return rows[0]


@app.get("/api/stats")
async def stats():
    return await query(
        """SELECT module, kind, count(*) AS total,
                  count(*) FILTER (WHERE ts > now() - interval '1 hour') AS last_hour,
                  max(ts) AS last_ts
           FROM events GROUP BY module, kind ORDER BY module, kind"""
    )


# -- write -----------------------------------------------------------------

class PublishRequest(BaseModel):
    module: str
    kind: str
    data: Any


@app.post("/api/publish", status_code=202)
async def publish_data(req: PublishRequest):
    """Publish data onto the bus as if it came from `module` (the ingestor stores it)."""
    publish(data_topic(req.module, req.kind), req.data)
    return {"published": data_topic(req.module, req.kind)}


@app.post("/api/modules/{name}/commands/{command}", status_code=202)
async def send_command(name: str, command: str, body: dict[str, Any] | None = None):
    publish(cmd_topic(name, command), body or {})
    return {"published": cmd_topic(name, command)}


@app.get("/api/kv/{namespace}")
async def kv_list(namespace: str):
    return await query("SELECT * FROM kv WHERE namespace = %s ORDER BY key", (namespace,))


@app.put("/api/kv/{namespace}/{key}")
async def kv_put(namespace: str, key: str, value: Any = Body(...)):
    await query(
        """INSERT INTO kv (namespace, key, value) VALUES (%s, %s, %s)
           ON CONFLICT (namespace, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
           RETURNING *""",
        (namespace, key, Jsonb(value)),
    )
    return {"namespace": namespace, "key": key, "value": value}


# -- live feed ---------------------------------------------------------------

@app.websocket("/api/live")
async def live(ws: WebSocket):
    await ws.accept()
    queue: asyncio.Queue = asyncio.Queue(maxsize=500)
    live_clients.add(queue)
    try:
        while True:
            event = await queue.get()
            if event.get("truncated"):
                rows = await query("SELECT * FROM events WHERE id = %s", (event["id"],))
                if rows:
                    event = rows[0]
            await ws.send_text(json.dumps(event, default=str))
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        live_clients.discard(queue)


app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", include_in_schema=False)
async def dashboard():
    return FileResponse("static/index.html")
