from __future__ import annotations

from ..config import Settings
from .base import InferenceError, InferenceProvider
from .hermes import HermesProvider
from .omlx import OMLXProvider
from .scripted import ScriptedProvider


def build_provider(settings: Settings) -> InferenceProvider:
    """Build exactly the configured provider. Fails closed; never substitutes another provider."""
    name = settings.inference_provider
    if name == "hermes":
        return HermesProvider(settings.hermes_base_url, settings.hermes_api_key.get_secret_value(), settings.hermes_model,
                              settings.request_timeout_seconds, settings.max_retries)
    if name == "omlx":
        return OMLXProvider(settings.omlx_base_url, settings.omlx_api_key.get_secret_value(), settings.omlx_model,
                            settings.request_timeout_seconds, settings.max_retries)
    if name == "scripted":
        if not settings.allow_scripted_provider:
            raise InferenceError(
                "The scripted provider is for automated tests only. Refusing to start without LGL_ALLOW_SCRIPTED_PROVIDER=1."
            )
        return ScriptedProvider(settings.scripted_responses_dir)
    raise InferenceError(f"Unknown inference provider '{name}'.")
