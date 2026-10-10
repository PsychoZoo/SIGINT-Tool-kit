"""Cloudflare Access check: requests that came through Cloudflare need a valid
Access token; requests from this machine don't."""

import asyncio
import base64
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

import access
from access import AccessDenied, AccessVerifier, access_token, came_through_proxy

TEAM = "myteam.cloudflareaccess.com"
AUD = "aud-tag-123"


def make_key(kid: str):
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = jwt.algorithms.RSAAlgorithm.to_jwk(private.public_key(), as_dict=True)
    jwk.update(kid=kid, alg="RS256", use="sig")
    return private, jwk


KEY, JWK = make_key("k1")
OTHER_KEY, _ = make_key("k1")


def token(key=KEY, kid="k1", **overrides) -> str:
    now = int(time.time())
    claims = {"aud": [AUD], "iss": f"https://{TEAM}", "iat": now, "exp": now + 300,
              "email": "me@example.com"}
    claims.update(overrides)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


class FakeKeys:
    def __init__(self, keys):
        self.keys, self.calls = keys, 0

    async def __call__(self):
        self.calls += 1
        return self.keys


def verify(verifier: AccessVerifier, tok):
    return asyncio.run(verifier.verify(tok))


@pytest.fixture
def verifier():
    return AccessVerifier(TEAM, AUD, fetch_keys=FakeKeys([JWK]))


def test_valid_token_is_accepted(verifier):
    claims = verify(verifier, token())
    assert claims["email"] == "me@example.com"


@pytest.mark.parametrize("bad", [
    {"aud": ["someone-else"]},
    {"iss": "https://evil.cloudflareaccess.com"},
    {"exp": int(time.time()) - 60},
])
def test_wrong_claims_are_refused(verifier, bad):
    with pytest.raises(AccessDenied):
        verify(verifier, token(**bad))


def test_signature_from_another_key_is_refused(verifier):
    with pytest.raises(AccessDenied):
        verify(verifier, token(key=OTHER_KEY))


def test_unknown_key_id_is_refused_and_refetches_at_most_once_a_minute():
    keys = FakeKeys([JWK])
    v = AccessVerifier(TEAM, AUD, fetch_keys=keys)
    for _ in range(5):
        with pytest.raises(AccessDenied):
            verify(v, token(kid="nope"))
    assert keys.calls == 1


def test_missing_or_garbage_token_is_refused(verifier):
    for tok in (None, "", "not.a.jwt"):
        with pytest.raises(AccessDenied):
            verify(verifier, tok)


def test_unsigned_token_is_refused(verifier):
    tok = jwt.encode({"aud": [AUD], "iss": f"https://{TEAM}", "exp": int(time.time()) + 60},
                     None, algorithm="none", headers={"kid": "k1"})
    with pytest.raises(AccessDenied):
        verify(verifier, tok)


def test_not_configured_refuses():
    v = AccessVerifier("", "", fetch_keys=FakeKeys([JWK]))
    with pytest.raises(AccessDenied, match="isn't set up"):
        verify(v, token())


def test_a_malformed_team_domain_counts_as_not_configured():
    v = AccessVerifier("evil.example.com/x@", AUD, fetch_keys=FakeKeys([JWK]))
    assert not v.configured
    with pytest.raises(AccessDenied):
        verify(v, token())


def test_a_non_string_key_id_is_refused_not_crashed(verifier):
    def part(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()
    # Built by hand: PyJWT won't even create a token like this.
    tok = f'{part({"alg": "RS256", "kid": ["x"]})}.{part({"aud": [AUD]})}.c2ln'
    with pytest.raises(AccessDenied):
        verify(verifier, tok)


def test_keys_are_fetched_right_after_boot(monkeypatch):
    monkeypatch.setattr(access.time, "monotonic", lambda: 5.0)  # host up for 5 s
    v = AccessVerifier(TEAM, AUD, fetch_keys=FakeKeys([JWK]))
    assert verify(v, token())["email"] == "me@example.com"


def test_a_slightly_wrong_clock_is_tolerated(verifier):
    verify(verifier, token(iat=int(time.time()) + 20))


def test_concurrent_requests_share_one_key_fetch():
    keys = FakeKeys([JWK])
    v = AccessVerifier(TEAM, AUD, fetch_keys=keys)

    async def many():
        return await asyncio.gather(*(v.verify(token()) for _ in range(20)))

    assert len(asyncio.run(many())) == 20
    assert keys.calls == 1


def test_team_domain_may_be_given_as_a_url():
    v = AccessVerifier("https://myteam.cloudflareaccess.com/", AUD, fetch_keys=FakeKeys([JWK]))
    assert verify(v, token())["email"] == "me@example.com"


def test_which_requests_count_as_proxied():
    for header in ("cf-connecting-ip", "CF-Ray", "cdn-loop", "x-forwarded-for", "forwarded", "true-client-ip"):
        assert came_through_proxy({header: "x"}), header
    assert not came_through_proxy({"host": "localhost:8080", "user-agent": "curl"})


def test_token_from_header_or_cookie():
    assert access_token({"cf-access-jwt-assertion": "a"}, {}) == "a"
    assert access_token({}, {"CF_Authorization": "b"}) == "b"
    assert access_token({}, {}) is None
