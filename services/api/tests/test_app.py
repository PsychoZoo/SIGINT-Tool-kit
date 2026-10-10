"""The API's own pages: the guide and API docs work with no internet, and the
Cloudflare Access rule applies to every page and the live feed."""

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import main
from access import AccessDenied
from guide import render_guide

THROUGH_CLOUDFLARE = {"cf-connecting-ip": "203.0.113.7"}


class StubVerifier:
    async def verify(self, tok):
        if tok != "good":
            raise AccessDenied("no valid Cloudflare Access token; see the guide")
        return {"email": "me@example.com"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "verifier", StubVerifier())
    return TestClient(main.app)  # not entered: no database or bus needed


def test_guide_is_served_locally(client):
    r = client.get("/guide")
    assert r.status_code == 200
    assert "<h1" in r.text and "Guide" in r.text


def test_pages_need_no_internet(client):
    for path in ("/", "/guide", "/docs"):
        body = client.get(path).text
        assert "cdn.jsdelivr" not in body and "unpkg.com" not in body, path
    assert client.get("/swagger/swagger-ui-bundle.js").status_code == 200


@pytest.fixture
def public_client(client, monkeypatch):
    monkeypatch.setattr(main, "REQUIRE_ACCESS", True)  # the api-public instance
    return client


def test_public_instance_needs_a_login_even_without_cloudflare_headers(public_client):
    assert public_client.get("/guide").status_code == 403
    assert public_client.get("/guide", headers={"cf-access-jwt-assertion": "good"}).status_code == 200


def test_public_instance_live_feed_needs_a_login(public_client):
    with pytest.raises(WebSocketDisconnect):
        with public_client.websocket_connect("/api/live"):
            pytest.fail("the live feed accepted a connection without an Access login")


def test_any_proxy_header_counts_as_proxied(client):
    assert client.get("/guide", headers={"x-forwarded-for": "203.0.113.7"}).status_code == 403


def test_other_websites_cant_send_commands(client):
    r = client.post("/api/publish", json={}, headers={"origin": "https://evil.example"})
    assert r.status_code == 403


def test_other_websites_cant_open_the_live_feed(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/api/live", headers={"origin": "https://evil.example"}):
            pytest.fail("accepted a cross-site live feed connection")


def test_unknown_host_names_are_refused(client):
    assert client.get("/guide", headers={"host": "rebind.evil.example"}).status_code == 400


@pytest.mark.parametrize("path", ["/", "/guide", "/docs", "/openapi.json", "/static/index.html"])
def test_through_cloudflare_without_token_is_refused(client, path):
    r = client.get(path, headers=THROUGH_CLOUDFLARE)
    assert r.status_code == 403
    assert "guide" in r.text


def test_through_cloudflare_with_token_is_allowed(client):
    r = client.get("/guide", headers={**THROUGH_CLOUDFLARE, "cf-access-jwt-assertion": "good"})
    assert r.status_code == 200


def test_live_feed_through_cloudflare_without_token_is_closed(client):
    with pytest.raises(WebSocketDisconnect) as closed:
        with client.websocket_connect("/api/live", headers=THROUGH_CLOUDFLARE):
            pytest.fail("the live feed accepted a connection without an Access login")
    assert closed.value.code == 1008


def test_guide_markdown_renders_and_raw_html_is_escaped():
    html = render_guide("# Title\n\nSome `code`.\n\n```bash\n./toolkit.sh setup\n```\n\n<script>alert(1)</script>\n")
    assert '<h1 id="title">Title</h1>' in html
    assert "<pre><code class=\"language-bash\">./toolkit.sh setup" in html
    assert "<script>" not in html and "&lt;script&gt;" in html
