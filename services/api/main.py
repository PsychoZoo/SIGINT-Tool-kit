"""REST + WebSocket API and web dashboard for the central database and bus."""

import asyncio
import contextlib
import json
import logging
import os
from datetime import datetime
from urllib.parse import urlsplit
from typing import Any

import paho.mqtt.client as mqtt
import psycopg
from fastapi import Body, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware
from paho.mqtt.enums import CallbackAPIVersion
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool
from pydantic import BaseModel
from swagger_ui_bundle import swagger_ui_path

from sigint_common import cmd_topic, data_topic
from sigint_common.config import DATABASE_URL, MQTT_HOST, MQTT_PASSWORD, MQTT_PORT, MQTT_USERNAME, NODE_NAME

from access import GUIDE_HINT, AccessDenied, AccessVerifier, access_token, came_through_proxy
from guide import guide_page

log = logging.getLogger("api")

pool = AsyncConnectionPool(DATABASE_URL, open=False, kwargs={"autocommit": True, "row_factory": dict_row})
bus = mqtt.Client(CallbackAPIVersion.VERSION2, client_id="api")
live_clients: set[asyncio.Queue] = set()
verifier = AccessVerifier.from_env()
# api-public (the instance cloudflared reaches) sets this: every request needs a
# Cloudflare Access login. The local instance requires it only for proxied requests.
REQUIRE_ACCESS = os.environ.get("API_REQUIRE_ACCESS") == "1"
DENIED = f"Cloudflare Access login required. {GUIDE_HINT}"
SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


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


# docs_url=None: /docs is served below from bundled files instead of a CDN, so
# it works with no internet.
app = FastAPI(title="SIGINT Tool-kit API", lifespan=lifespan, docs_url=None, redoc_url=None)


def needs_access(headers) -> bool:
    return REQUIRE_ACCESS or came_through_proxy(headers)


async def access_denied(headers, cookies, what: str) -> bool:
    """True (and logged) if this request needs an Access login and lacks a valid one."""
    if not needs_access(headers):
        return False
    try:
        await verifier.verify(access_token(headers, cookies))
        return False
    except AccessDenied as exc:
        log.warning("refused %s: %s", what, exc)
        return True


def cross_origin(headers) -> bool:
    """A browser request started by another website (CSRF, WebSocket hijacking)."""
    origin = headers.get("origin")
    return bool(origin) and urlsplit(origin).netloc != headers.get("host")


@app.middleware("http")
async def protect(request: Request, call_next):
    if await access_denied(request.headers, request.cookies, f"{request.method} {request.url.path}"):
        return PlainTextResponse(DENIED, status_code=403)
    if request.method not in SAFE_METHODS and cross_origin(request.headers):
        return PlainTextResponse("Cross-site request refused.", status_code=403)
    return await call_next(request)


# Only answer to our own names: blocks DNS-rebinding attacks from web pages.
ALLOWED_HOSTS = ["localhost", "127.0.0.1", "api", "api-public"] + [
    h for h in [os.environ.get("DASHBOARD_CLOUDFLARE_HOSTNAME", "")] + os.environ.get("API_ALLOWED_HOSTS", "").split()
    if h
]
app.add_middleware(TrustedHostMiddleware, allowed_hosts=ALLOWED_HOSTS)


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


@app.get("/api/nodes")
async def list_nodes():
    """Every node (device) and whether it is currently linked to the master."""
    return await query(
        """SELECT n.node, n.status, n.first_seen, n.last_seen,
                  count(m.name) FILTER (WHERE m.status = 'online') AS modules_online,
                  count(m.name) AS modules_total
           FROM modules n
           LEFT JOIN modules m ON m.node = n.node AND m.name <> 'node'
           WHERE n.name = 'node'
           GROUP BY n.node, n.status, n.first_seen, n.last_seen
           ORDER BY n.node <> %s, n.node""",
        (NODE_NAME,),
    )


@app.get("/api/modules")
async def list_modules(node: str | None = None):
    if node:
        return await query("SELECT * FROM modules WHERE node = %s AND name <> 'node' ORDER BY name", (node,))
    return await query("SELECT * FROM modules WHERE name <> 'node' ORDER BY node, name")


@app.get("/api/events")
async def list_events(
    node: str | None = None,
    module: str | None = None,
    kind: str | None = None,
    since: datetime | None = None,
    after_id: int | None = None,
    contains: str | None = Query(None, description='JSON the event data must contain, e.g. {"icao":"a1b2c3"}'),
    limit: int = Query(100, ge=1, le=1000),
):
    where, params = [], {}
    if node:
        where.append("node = %(node)s")
        params["node"] = node
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
        """SELECT node, module, kind, count(*) AS total,
                  count(*) FILTER (WHERE ts > now() - interval '1 hour') AS last_hour,
                  max(ts) AS last_ts
           FROM events GROUP BY node, module, kind ORDER BY node, module, kind"""
    )


# -- write -----------------------------------------------------------------

class PublishRequest(BaseModel):
    module: str
    kind: str
    data: Any
    node: str = NODE_NAME


@app.post("/api/publish", status_code=202)
async def publish_data(req: PublishRequest):
    """Publish data onto the bus as if it came from `module` (the ingestor stores it)."""
    topic = data_topic(req.module, req.kind, req.node)
    publish(topic, req.data)
    return {"published": topic}


@app.post("/api/nodes/{node}/modules/{name}/commands/{command}", status_code=202)
async def send_command(node: str, name: str, command: str, body: dict[str, Any] | None = None):
    """Send a command to a module on any node (delivered over the node's link)."""
    topic = cmd_topic(name, command, node)
    publish(topic, body or {})
    return {"published": topic}


@app.post("/api/modules/{name}/commands/{command}", status_code=202)
async def send_command_master(name: str, command: str, body: dict[str, Any] | None = None):
    """Shortcut for a module on the master."""
    return await send_command(NODE_NAME, name, command, body)


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
    # HTTP middleware doesn't see WebSockets: apply the same rules here.
    if cross_origin(ws.headers) or await access_denied(ws.headers, ws.cookies, "live feed"):
        await ws.close(code=1008)  # policy violation
        return
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
app.mount("/swagger", StaticFiles(directory=swagger_ui_path), name="swagger")


@app.get("/docs", include_in_schema=False)
async def api_docs():
    return get_swagger_ui_html(
        openapi_url=app.openapi_url,
        title=f"{app.title} - API docs",
        swagger_js_url="/swagger/swagger-ui-bundle.js",
        swagger_css_url="/swagger/swagger-ui.css",
        swagger_favicon_url="/swagger/favicon-32x32.png",
    )


@app.get("/guide", include_in_schema=False)
async def guide():
    return HTMLResponse(guide_page())


@app.get("/", include_in_schema=False)
async def dashboard():
    return FileResponse("static/index.html")
