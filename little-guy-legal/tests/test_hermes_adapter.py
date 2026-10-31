"""Contract tests for the Hermes adapter against a loopback fake that mimics hermes-agent 0.19.0 behavior."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from app.inference.base import CancelToken, InferenceError, InferenceRequest, InferenceUnavailable
from app.inference.hermes import HermesProvider

KEY = "fake-hermes-key-0123456789abcdef"


class FakeHermes(BaseHTTPRequestHandler):
    seen: list[dict] = []
    mode = "ok"

    def log_message(self, *a):  # silence
        pass

    def _auth(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {KEY}"

    def do_GET(self):
        if self.path in ("/v1/health", "/health"):
            return self._json(200, {"status": "ok"})
        if not self._auth():
            return self._json(401, {"error": {"code": "invalid_api_key", "message": "bad key"}})
        if self.path == "/v1/models":
            return self._json(200, {"data": [{"id": "little-guy-legal"}]})
        if self.path == "/v1/toolsets":
            return self._json(200, {"enabled": []})
        self._json(404, {})

    def do_DELETE(self):
        if not self._auth():
            return self._json(401, {})
        FakeHermes.seen.append({"deleted": self.path})
        self._json(200, {"deleted": True})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self._auth():
            return self._json(401, {"error": {"code": "invalid_api_key"}})
        FakeHermes.seen.append({"path": self.path, "session": self.headers.get("X-Hermes-Session-Id"), "body": body})
        if FakeHermes.mode == "incomplete":
            return self._json(200, {"choices": [{"index": 0, "message": {"role": "assistant", "content": "partial"}, "finish_reason": "error"}],
                                    "hermes": {"completed": False, "failed": True, "error": "tool loop aborted", "error_code": "agent_incomplete"}})
        if FakeHermes.mode == "500":
            return self._json(500, {"error": {"message": "boom"}})
        self._json(200, {"id": "chatcmpl-x", "object": "chat.completion", "model": "little-guy-legal",
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": "{\"ok\": true}"}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13}},
                   extra={"X-Hermes-Session-Id": self.headers.get("X-Hermes-Session-Id", "")})

    def _json(self, code, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)


@pytest.fixture
def fake_hermes():
    FakeHermes.seen = []
    FakeHermes.mode = "ok"
    srv = HTTPServer(("127.0.0.1", 0), FakeHermes)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def _req(session="lgl-abcdef12-knowledge-0123456789abcdef"):
    return InferenceRequest(system_prompt="sys", user_prompt="hello", session_id=session, stage="knowledge", timeout_seconds=5)


def test_hermes_adapter_sends_bearer_and_session_header(fake_hermes):
    p = HermesProvider(fake_hermes, KEY, "", timeout=5, max_retries=0)
    resp = p.complete(_req(), CancelToken())
    assert resp.text == '{"ok": true}' and resp.prompt_tokens == 10
    call = FakeHermes.seen[-1]
    assert call["path"] == "/v1/chat/completions" and call["session"] == "lgl-abcdef12-knowledge-0123456789abcdef"
    assert call["body"]["messages"][0]["role"] == "system" and call["body"]["stream"] is False
    health = p.health()
    assert health["ok"] and health["models"] == ["little-guy-legal"] and health["toolsets"] == {"enabled": []}
    assert p.cleanup_session("lgl-abcdef12-knowledge-0123456789abcdef") is True
    assert FakeHermes.seen[-1]["deleted"].endswith("/api/sessions/lgl-abcdef12-knowledge-0123456789abcdef")


def test_hermes_adapter_rejects_bad_key_and_requires_key(fake_hermes):
    with pytest.raises(InferenceError):
        HermesProvider(fake_hermes, "", "", timeout=5)
    p = HermesProvider(fake_hermes, "wrong-key-0123456789abcdef", "", timeout=5, max_retries=0)
    with pytest.raises(InferenceUnavailable) as exc:
        p.complete(_req())
    assert "API key" in str(exc.value)


def test_hermes_incomplete_run_is_an_error_not_silent(fake_hermes):
    FakeHermes.mode = "incomplete"
    p = HermesProvider(fake_hermes, KEY, "", timeout=5, max_retries=0)
    with pytest.raises(InferenceError) as exc:
        p.complete(_req())
    assert "incomplete" in str(exc.value)


def test_hermes_5xx_is_retried_then_surfaced(fake_hermes):
    FakeHermes.mode = "500"
    p = HermesProvider(fake_hermes, KEY, "", timeout=5, max_retries=1)
    with pytest.raises(InferenceUnavailable):
        p.complete(_req())
    assert sum(1 for s in FakeHermes.seen if s.get("path")) == 2


def test_unsafe_session_id_rejected(fake_hermes):
    p = HermesProvider(fake_hermes, KEY, "", timeout=5)
    with pytest.raises(InferenceError):
        p.complete(_req(session="../../etc/passwd"))
