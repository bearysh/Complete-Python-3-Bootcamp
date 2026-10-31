"""Hermes Agent API-server adapter (verified against hermes-agent 0.19.0 source).

* Endpoint: ``POST /v1/chat/completions`` on the gateway API server
  (``gateway/platforms/api_server.py``), default bind 127.0.0.1:8642.
* Auth: ``Authorization: Bearer <API_SERVER_KEY>`` (server refuses to start without a key).
* Isolation: ``X-Hermes-Session-Id`` selects the Hermes session. A never-used id
  yields an empty history, so each stage gets a fresh, unpredictable id.
  Without the header Hermes derives a deterministic id from the prompt, which
  could collide across cases, so the header is mandatory here.
* ``temperature``/``max_tokens`` in the body are ignored by Hermes (the profile
  config controls generation). ``model`` is ignored unless it matches a route.
* Non-streaming responses carry only the final assistant text; failures add a
  ``hermes`` object and ``X-Hermes-Completed/Partial/Error`` headers.
* ``DELETE /api/sessions/{id}`` removes the transcript from the profile's state.db.
"""
from __future__ import annotations

import re
from typing import Any

import httpx

from .base import InferenceError, InferenceRequest, ProviderInfo
from .openai_compat import OpenAICompatProvider

SAFE_SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_\-]{7,120}$")


class HermesProvider(OpenAICompatProvider):
    name = "hermes"
    label = "Hermes API server (little-guy-legal profile)"

    def __init__(self, base_url: str, api_key: str, model: str, timeout: float, max_retries: int = 2):
        if not api_key:
            raise InferenceError("LGL_HERMES_API_KEY is not set. The Hermes API server requires a Bearer key.")
        super().__init__(base_url, api_key, model, timeout, max_retries)
        self.info = ProviderInfo(self.name, self.label, base_url, model or "(profile default)", True,
                                 notes=["Generation parameters are governed by the Hermes profile config, not per request."])

    def _extra_headers(self, request: InferenceRequest) -> dict[str, str]:
        if not SAFE_SESSION_RE.match(request.session_id):
            raise InferenceError("Internal error: unsafe Hermes session id.")
        return {"X-Hermes-Session-Id": request.session_id}

    def _check_provider_specific(self, resp: httpx.Response, data: dict[str, Any]) -> None:
        hermes = data.get("hermes") if isinstance(data, dict) else None
        if isinstance(hermes, dict) and (hermes.get("failed") or hermes.get("completed") is False):
            raise InferenceError(
                f"Hermes reported an incomplete run ({hermes.get('error_code') or 'unknown'}): {str(hermes.get('error') or '')[:200]}"
            )
        if resp.headers.get("X-Hermes-Completed", "").lower() == "false":
            raise InferenceError("Hermes reported the run did not complete.")

    def health(self) -> dict[str, Any]:
        out: dict[str, Any] = {"endpoint": self.info.endpoint}
        try:
            h = self._client.get("/v1/health", timeout=10.0)
            out["server"] = "up" if h.status_code == 200 else f"HTTP {h.status_code}"
        except httpx.HTTPError as exc:
            return {"ok": False, "detail": f"Hermes API server unreachable ({type(exc).__name__}). Run: hermes -p little-guy-legal gateway run", **out}
        base = super().health()
        out.update(base)
        try:
            caps = self._client.get("/v1/toolsets", timeout=10.0)
            if caps.status_code == 200:
                out["toolsets"] = caps.json()
        except (httpx.HTTPError, ValueError):
            pass
        return out

    def cleanup_session(self, session_id: str) -> bool:
        if not SAFE_SESSION_RE.match(session_id):
            return False
        try:
            r = self._client.delete(f"/api/sessions/{session_id}", timeout=15.0)
        except httpx.HTTPError:
            return False
        return r.status_code in (200, 204, 404)
