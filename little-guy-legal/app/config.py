"""Application configuration.

All settings are read from environment variables prefixed with ``LGL_`` (or a
local ``.env`` file). Secrets are held in ``SecretStr`` fields and are never
logged or serialized by the application.
"""
from __future__ import annotations

import ipaddress
from functools import lru_cache
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

ProviderName = Literal["hermes", "omlx", "scripted"]

LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def is_loopback_url(url: str) -> bool:
    """Return True only when ``url`` points at a loopback interface."""
    try:
        parsed = urlparse(url)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    if not host or parsed.scheme not in {"http", "https"}:
        return False
    if host in LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="LGL_", env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    data_dir: Path = Field(default=Path("~/LittleGuyLegal/data"))
    host: str = "127.0.0.1"
    port: int = 8765

    inference_provider: ProviderName = "hermes"

    hermes_base_url: str = "http://127.0.0.1:8642"
    hermes_api_key: SecretStr = SecretStr("")
    hermes_model: str = ""

    omlx_base_url: str = "http://127.0.0.1:8000"
    omlx_api_key: SecretStr = SecretStr("")
    omlx_model: str = ""

    request_timeout_seconds: float = 900.0
    max_retries: int = 2
    max_output_tokens: int = 6000
    max_evidence_chars: int = 60000
    temperature: float = 0.2

    # Test-only provider. Both must be set for ``scripted`` to be selectable.
    allow_scripted_provider: bool = False
    scripted_responses_dir: Path = Path("fixtures/scripted_responses")

    # Hermes session retention in days (0 = delete immediately after a run).
    session_retention_days: int = 30

    @field_validator("data_dir", "scripted_responses_dir", mode="after")
    @classmethod
    def _expand(cls, value: Path) -> Path:
        return value.expanduser()

    @field_validator("host")
    @classmethod
    def _host_must_be_loopback(cls, value: str) -> str:
        if value not in LOOPBACK_HOSTS and not ipaddress.ip_address(value).is_loopback:
            raise ValueError(
                "Milestone 1 binds to loopback only; LGL_HOST must be 127.0.0.1 or localhost"
            )
        return value

    @property
    def db_path(self) -> Path:
        return self.data_dir / "lgl.sqlite3"

    @property
    def cases_dir(self) -> Path:
        return self.data_dir / "cases"

    @property
    def logs_dir(self) -> Path:
        return self.data_dir / "logs"

    @property
    def library_dir(self) -> Path:
        return Path(__file__).resolve().parent.parent / "library"

    def ensure_dirs(self) -> None:
        for p in (self.data_dir, self.cases_dir, self.logs_dir):
            p.mkdir(parents=True, exist_ok=True)


@lru_cache
def get_settings() -> Settings:
    return Settings()


def reset_settings_cache() -> None:
    get_settings.cache_clear()
