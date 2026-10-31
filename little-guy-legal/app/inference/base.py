"""Inference provider abstraction.

Primary path:   Application -> Hermes API server (dedicated profile) -> OMLX -> Qwen
Diagnostic:     Application -> OMLX -> Qwen (direct, benchmarking/troubleshooting)
Test only:      Scripted fixture replay (no inference; loudly labelled)

There is deliberately *no* automatic switching between providers.
"""
from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Any, Protocol


class InferenceError(RuntimeError):
    """Base class for inference failures. Messages are safe to show operators."""


class InferenceUnavailable(InferenceError):
    """The local inference service could not be reached or refused the request."""


class InferenceTimeout(InferenceError):
    pass


class InferenceCancelled(InferenceError):
    pass


class EgressBlocked(InferenceError):
    """A request would have left the loopback interface. Always fatal; never retried."""


@dataclass
class InferenceRequest:
    system_prompt: str
    user_prompt: str
    session_id: str
    stage: str
    max_tokens: int = 4000
    temperature: float = 0.2
    timeout_seconds: float = 900.0
    history: list[dict[str, str]] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class InferenceResponse:
    text: str
    model: str
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    duration_ms: int | None = None
    provider: str = ""
    raw_meta: dict[str, Any] = field(default_factory=dict)


class CancelToken:
    def __init__(self) -> None:
        self._event = threading.Event()

    def cancel(self) -> None:
        self._event.set()

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()


@dataclass
class ProviderInfo:
    name: str
    label: str
    endpoint: str
    model: str
    is_real_inference: bool
    notes: list[str] = field(default_factory=list)


class InferenceProvider(Protocol):
    info: ProviderInfo

    def health(self) -> dict[str, Any]: ...

    def complete(self, request: InferenceRequest, cancel: CancelToken | None = None) -> InferenceResponse: ...

    def cleanup_session(self, session_id: str) -> bool: ...
