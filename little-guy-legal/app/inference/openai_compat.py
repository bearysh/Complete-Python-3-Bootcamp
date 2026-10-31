"""OpenAI-compatible chat-completions client bound to loopback. Shared by Hermes and OMLX adapters."""
from __future__ import annotations

import threading
import time
from typing import Any

import httpx

from .base import (
    CancelToken,
    InferenceCancelled,
    InferenceError,
    InferenceRequest,
    InferenceResponse,
    InferenceTimeout,
    InferenceUnavailable,
    ProviderInfo,
)
from .egress import make_loopback_client

_POLL_SECONDS = 0.5


class OpenAICompatProvider:
    """Serializes requests (one local inference at a time) and maps errors to actionable messages."""

    name = "openai_compat"
    label = "OpenAI-compatible local server"

    def __init__(self, base_url: str, api_key: str, model: str, timeout: float, max_retries: int = 2):
        self._api_key = api_key
        self.model = model
        self.timeout = timeout
        self.max_retries = max(0, max_retries)
        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        self._client = make_loopback_client(base_url, timeout, headers)
        self._lock = threading.Lock()
        self.info = ProviderInfo(self.name, self.label, base_url, model, True)

    # -- helpers --------------------------------------------------------
    def _extra_headers(self, request: InferenceRequest) -> dict[str, str]:
        return {}

    def _body(self, request: InferenceRequest) -> dict[str, Any]:
        body: dict[str, Any] = {
            "model": self.model or "default",
            "messages": [
                {"role": "system", "content": request.system_prompt},
                {"role": "user", "content": request.user_prompt},
                *request.history,
            ],
            "stream": False,
            "temperature": request.temperature,
            "max_tokens": request.max_tokens,
        }
        return body

    def _interpret(self, data: dict[str, Any], started: float) -> InferenceResponse:
        choices = data.get("choices") or []
        if not choices:
            raise InferenceError(f"{self.label} returned no choices.")
        message = choices[0].get("message") or {}
        text = message.get("content")
        if not isinstance(text, str) or not text.strip():
            raise InferenceError(f"{self.label} returned an empty response.")
        usage = data.get("usage") or {}
        return InferenceResponse(
            text=text,
            model=str(data.get("model") or self.model),
            prompt_tokens=usage.get("prompt_tokens"),
            completion_tokens=usage.get("completion_tokens"),
            duration_ms=int((time.monotonic() - started) * 1000),
            provider=self.name,
            raw_meta={"finish_reason": choices[0].get("finish_reason")},
        )

    def _post_with_cancel(self, path: str, body: dict[str, Any], headers: dict[str, str], cancel: CancelToken | None,
                          timeout: float) -> httpx.Response:
        """Issue the request on a worker thread so cancellation can abort the wait."""
        result: dict[str, Any] = {}

        def worker() -> None:
            try:
                result["response"] = self._client.post(path, json=body, headers=headers, timeout=timeout)
            except Exception as exc:  # propagated below
                result["error"] = exc

        t = threading.Thread(target=worker, name="lgl-inference", daemon=True)
        t.start()
        while t.is_alive():
            t.join(_POLL_SECONDS)
            if cancel is not None and cancel.cancelled:
                # The HTTP request will be abandoned; the local server finishes or times out on its own.
                raise InferenceCancelled("Inference cancelled by operator.")
        if "error" in result:
            raise result["error"]
        return result["response"]

    # -- public API -----------------------------------------------------
    def complete(self, request: InferenceRequest, cancel: CancelToken | None = None) -> InferenceResponse:
        headers = self._extra_headers(request)
        body = self._body(request)
        attempt = 0
        last_error: Exception | None = None
        with self._lock:  # one local inference at a time
            while attempt <= self.max_retries:
                attempt += 1
                started = time.monotonic()
                try:
                    resp = self._post_with_cancel("/v1/chat/completions", body, headers, cancel, request.timeout_seconds)
                except InferenceCancelled:
                    raise
                except httpx.TimeoutException as exc:
                    last_error = InferenceTimeout(
                        f"{self.label} did not answer within {request.timeout_seconds:.0f}s. Increase LGL_REQUEST_TIMEOUT_SECONDS or use a smaller model/context."
                    )
                    if attempt > self.max_retries:
                        raise last_error from exc
                    continue
                except httpx.ConnectError as exc:
                    raise InferenceUnavailable(
                        f"Cannot connect to {self.label} at {self.info.endpoint}. Start the local service and retry."
                    ) from exc
                except httpx.HTTPError as exc:
                    raise InferenceUnavailable(f"{self.label} transport error: {type(exc).__name__}") from exc
                if resp.status_code in (401, 403):
                    raise InferenceUnavailable(f"{self.label} rejected the API key (HTTP {resp.status_code}). Check the configured key.")
                if resp.status_code == 404:
                    raise InferenceUnavailable(f"{self.label} has no /v1/chat/completions endpoint at {self.info.endpoint}.")
                if resp.status_code >= 500 or resp.status_code == 429:
                    last_error = InferenceUnavailable(f"{self.label} returned HTTP {resp.status_code}: {_safe_error(resp)}")
                    if attempt > self.max_retries:
                        raise last_error
                    time.sleep(min(2.0 * attempt, 10.0))
                    continue
                if resp.status_code >= 400:
                    raise InferenceError(f"{self.label} rejected the request (HTTP {resp.status_code}): {_safe_error(resp)}")
                try:
                    data = resp.json()
                except ValueError as exc:
                    raise InferenceError(f"{self.label} returned non-JSON output.") from exc
                self._check_provider_specific(resp, data)
                return self._interpret(data, started)
        raise last_error or InferenceError("Inference failed.")

    def _check_provider_specific(self, resp: httpx.Response, data: dict[str, Any]) -> None:
        return None

    def health(self) -> dict[str, Any]:
        try:
            r = self._client.get("/v1/models", timeout=10.0)
        except httpx.HTTPError as exc:
            return {"ok": False, "detail": f"unreachable ({type(exc).__name__})", "endpoint": self.info.endpoint}
        if r.status_code != 200:
            return {"ok": False, "detail": f"HTTP {r.status_code}", "endpoint": self.info.endpoint}
        try:
            models = [m.get("id") for m in (r.json().get("data") or []) if isinstance(m, dict)]
        except ValueError:
            models = []
        ok = bool(models) and (not self.model or self.model in models)
        return {"ok": ok, "models": models, "configured_model": self.model, "endpoint": self.info.endpoint}

    def cleanup_session(self, session_id: str) -> bool:
        return True

    def close(self) -> None:
        self._client.close()


def _safe_error(resp: httpx.Response) -> str:
    """Extract a short error message without echoing request content."""
    try:
        data = resp.json()
        err = data.get("error")
        if isinstance(err, dict):
            return str(err.get("message") or err.get("code") or "")[:200]
        if isinstance(err, str):
            return err[:200]
    except ValueError:
        pass
    return resp.text[:120].replace("\n", " ")
