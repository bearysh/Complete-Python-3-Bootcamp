"""TEST-ONLY provider that replays fixture outputs. Performs no inference.

Selectable only when BOTH ``LGL_INFERENCE_PROVIDER=scripted`` and
``LGL_ALLOW_SCRIPTED_PROVIDER=1`` are set. Every surface (health endpoint, UI
banner, report metadata, PDF cover) marks runs made with it as non-model output.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .base import CancelToken, InferenceError, InferenceRequest, InferenceResponse, ProviderInfo


class ScriptedProvider:
    name = "scripted"
    label = "SCRIPTED TEST FIXTURE — NOT MODEL OUTPUT"

    def __init__(self, responses_dir: Path, variant: str = "default"):
        self.dir = Path(responses_dir)
        self.variant = variant
        if not self.dir.is_dir():
            raise InferenceError(f"Scripted responses directory not found: {self.dir}")
        self.info = ProviderInfo(self.name, self.label, str(self.dir), f"fixture:{variant}", False,
                                 notes=["Outputs are canned fixtures used for automated testing. No AI analysis occurred."])
        self.calls: list[dict[str, Any]] = []

    def _load(self, stage: str) -> Any:
        for candidate in (self.dir / self.variant / f"{stage}.json", self.dir / "default" / f"{stage}.json"):
            if candidate.exists():
                return json.loads(candidate.read_text())
        raise InferenceError(f"No scripted response for stage '{stage}' in {self.dir}")

    def complete(self, request: InferenceRequest, cancel: CancelToken | None = None) -> InferenceResponse:
        if cancel is not None and cancel.cancelled:
            from .base import InferenceCancelled

            raise InferenceCancelled("cancelled")
        self.calls.append({"stage": request.stage, "session_id": request.session_id,
                           "system_len": len(request.system_prompt), "user_len": len(request.user_prompt)})
        payload = self._load(request.stage)
        text = payload if isinstance(payload, str) else json.dumps(payload)
        time.sleep(0.05)
        return InferenceResponse(text=text, model=self.info.model, prompt_tokens=len(request.user_prompt) // 4,
                                 completion_tokens=len(text) // 4, duration_ms=50, provider=self.name)

    def health(self) -> dict[str, Any]:
        return {"ok": True, "warning": "Scripted test provider active. No real inference.", "dir": str(self.dir)}

    def cleanup_session(self, session_id: str) -> bool:
        return True
