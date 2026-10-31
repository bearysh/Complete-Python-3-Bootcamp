"""Loopback-only egress guard for the inference path.

Defense in depth, in application code:
1. Provider base URLs are validated at construction; a non-loopback URL raises
   ``EgressBlocked`` and the provider is never created.
2. The HTTP client is created with ``trust_env=False`` so HTTP(S)_PROXY
   variables cannot redirect traffic off-box.
3. A request hook re-checks every outgoing request (including redirects) and
   aborts if the host is not loopback.

This does not replace OS-level egress controls; see docs/SECURITY.md.
"""
from __future__ import annotations

import httpx

from ..config import is_loopback_url
from .base import EgressBlocked


def assert_loopback(url: str, what: str = "inference endpoint") -> str:
    if not is_loopback_url(url):
        raise EgressBlocked(
            f"Refusing to use {what} '{_redact(url)}': case processing may only talk to loopback (127.0.0.1/localhost)."
        )
    return url.rstrip("/")


def _redact(url: str) -> str:
    # Never echo credentials that might be embedded in a URL.
    try:
        parsed = httpx.URL(url)
        return f"{parsed.scheme}://{parsed.host}:{parsed.port or ''}{parsed.path}"
    except Exception:
        return "<unparseable url>"


def _guard_request(request: httpx.Request) -> None:
    if not is_loopback_url(str(request.url)):
        raise EgressBlocked(f"Blocked outbound request to non-loopback host '{request.url.host}'.")


def make_loopback_client(base_url: str, timeout: float, headers: dict[str, str] | None = None) -> httpx.Client:
    assert_loopback(base_url)
    return httpx.Client(
        base_url=base_url,
        timeout=httpx.Timeout(timeout, connect=10.0),
        headers=headers or {},
        trust_env=False,
        follow_redirects=False,
        event_hooks={"request": [_guard_request]},
    )
