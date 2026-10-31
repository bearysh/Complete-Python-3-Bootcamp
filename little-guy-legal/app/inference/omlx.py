"""Direct OMLX (OpenAI-compatible) adapter — diagnostic/benchmark path only.

OMLX exposes an OpenAI-compatible server on the Mac mini. This adapter is
selected only by explicit configuration (``LGL_INFERENCE_PROVIDER=omlx``); the
application never falls back to it automatically.
"""
from __future__ import annotations

from .base import InferenceError, ProviderInfo
from .openai_compat import OpenAICompatProvider


class OMLXProvider(OpenAICompatProvider):
    name = "omlx"
    label = "OMLX local server (direct)"

    def __init__(self, base_url: str, api_key: str, model: str, timeout: float, max_retries: int = 2):
        if not model:
            raise InferenceError("LGL_OMLX_MODEL must name an exact model id served by OMLX (see GET /v1/models).")
        super().__init__(base_url, api_key, model, timeout, max_retries)
        self.info = ProviderInfo(self.name, self.label, base_url, model, True,
                                 notes=["Diagnostic path: bypasses the Hermes agent layer but still runs only on loopback."])
