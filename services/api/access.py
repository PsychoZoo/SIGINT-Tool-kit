"""Cloudflare Access login check for the dashboard and API.

Two instances of the API run on the master:
  api         on 127.0.0.1:8080 for this machine; no login.
  api-public  reachable only by cloudflared, on a separate Docker network
              (API_REQUIRE_ACCESS=1). Every request needs a valid Cloudflare
              Access login, so the dashboard can't be on the internet without
              one, even if the Access policy or Cloudflare's headers are wrong.
The local instance also refuses anything that looks proxied (Cloudflare or other
forwarding headers) without a valid login, as a second layer.

Settings (in .env): CF_ACCESS_TEAM_DOMAIN (e.g. myteam.cloudflareaccess.com) and
CF_ACCESS_AUD (the Access application's "Application Audience (AUD) Tag"). If
they're missing or invalid, every request that needs a login is refused.
"""

import asyncio
import json
import logging
import os
import re
import time
import urllib.request
from collections.abc import Awaitable, Callable, Mapping

import jwt

log = logging.getLogger("api.access")

GUIDE_HINT = 'See "Reach the dashboard from anywhere" in the guide (docs/GUIDE.md, or /guide on the master).'
KEY_REFRESH_SECONDS = 3600  # Cloudflare rotates Access signing keys periodically
MIN_REFETCH_SECONDS = 60    # an unknown key id can't make us hammer Cloudflare
FETCH_TIMEOUT_SECONDS = 10
CLOCK_LEEWAY_SECONDS = 30   # tolerate a master clock that's slightly off
TEAM_DOMAIN_RE = re.compile(r"^[a-z0-9-]+\.cloudflareaccess\.com$")
PROXY_HEADERS = {"cdn-loop", "x-forwarded-for", "x-forwarded-host", "forwarded", "true-client-ip", "x-real-ip"}

KeyFetcher = Callable[[], Awaitable[list[dict]]]


class AccessDenied(Exception):
    """The request needs a Cloudflare Access login and doesn't have a valid one."""


def came_through_proxy(headers: Mapping[str, str]) -> bool:
    """Any sign the request was forwarded (Cloudflare adds several cf-* headers)."""
    return any(name.lower().startswith("cf-") or name.lower() in PROXY_HEADERS for name in headers)


def access_token(headers: Mapping[str, str], cookies: Mapping[str, str]) -> str | None:
    return headers.get("cf-access-jwt-assertion") or cookies.get("CF_Authorization") or None


def _team_domain(value: str) -> str:
    value = value.strip().lower().removeprefix("https://").removeprefix("http://").rstrip("/")
    if value and not TEAM_DOMAIN_RE.match(value):
        log.error("CF_ACCESS_TEAM_DOMAIN %r isn't like your-team.cloudflareaccess.com; logins are refused", value)
        return ""
    return value


class AccessVerifier:
    def __init__(self, team_domain: str, audience: str, fetch_keys: KeyFetcher | None = None):
        self.team_domain = _team_domain(team_domain)
        self.audience = audience.strip()
        self._fetch_keys = fetch_keys or self._fetch_from_cloudflare
        self._keys: dict[str, object] = {}       # kid -> parsed public key
        self._fetched_at = float("-inf")         # never fetched yet
        self._lock = asyncio.Lock()

    @classmethod
    def from_env(cls) -> "AccessVerifier":
        return cls(os.environ.get("CF_ACCESS_TEAM_DOMAIN", ""), os.environ.get("CF_ACCESS_AUD", ""))

    @property
    def configured(self) -> bool:
        return bool(self.team_domain and self.audience)

    @property
    def issuer(self) -> str:
        return f"https://{self.team_domain}"

    async def _fetch_from_cloudflare(self) -> list[dict]:
        url = f"{self.issuer}/cdn-cgi/access/certs"

        def get() -> list[dict]:
            with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_SECONDS) as resp:  # noqa: S310 (https, validated domain)
                return json.load(resp)["keys"]

        return await asyncio.to_thread(get)

    async def _refresh(self) -> None:
        keys = await self._fetch_keys()
        parsed = {}
        for jwk in keys:
            try:
                parsed[jwk["kid"]] = jwt.PyJWK(jwk, algorithm="RS256").key
            except (KeyError, TypeError, jwt.PyJWTError) as exc:
                log.warning("ignoring an unusable Cloudflare Access key: %s", exc)
        self._keys = parsed

    async def _key(self, kid: str):
        # One fetch at a time: concurrent requests wait for it instead of piling up.
        async with self._lock:
            age = time.monotonic() - self._fetched_at
            if age > KEY_REFRESH_SECONDS or (kid not in self._keys and age > MIN_REFETCH_SECONDS):
                self._fetched_at = time.monotonic()
                try:
                    await self._refresh()
                except Exception as exc:  # network trouble: keep the keys we have
                    log.warning("couldn't fetch Cloudflare Access keys from %s: %s", self.issuer, exc)
            return self._keys.get(kid)

    async def verify(self, token: str | None) -> dict:
        """Returns the token's claims, or raises AccessDenied (never anything else)."""
        if not self.configured:
            raise AccessDenied("Cloudflare Access isn't set up on this master (CF_ACCESS_TEAM_DOMAIN, CF_ACCESS_AUD)")
        if not token:
            raise AccessDenied("no Cloudflare Access login on the request")
        try:
            kid = jwt.get_unverified_header(token).get("kid")
            if not isinstance(kid, str) or not kid:
                raise AccessDenied("token without a key id")
            key = await self._key(kid)
            if key is None:
                raise AccessDenied("token signed with an unknown key")
            return jwt.decode(
                token, key=key, algorithms=["RS256"], audience=self.audience, issuer=self.issuer,
                leeway=CLOCK_LEEWAY_SECONDS, options={"require": ["exp", "iat", "aud", "iss"]},
            )
        except AccessDenied:
            raise
        except jwt.PyJWTError as exc:
            raise AccessDenied(f"invalid token: {exc}") from exc
        except Exception as exc:  # any bug here must refuse, not let through or crash
            log.exception("unexpected error checking a Cloudflare Access token")
            raise AccessDenied("couldn't check the token") from exc
