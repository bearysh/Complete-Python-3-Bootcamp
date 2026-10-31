"""Case-scoped, content-free logging. Secrets and document text are never logged."""
from __future__ import annotations

import logging
import logging.handlers
import re
from pathlib import Path

from .config import Settings

# key=value / key: value forms, and bare "Bearer <token>" / "sk-..." style tokens
SECRET_KV_RE = re.compile(r"(?i)\b(api[_-]?key|authorization|token|secret|password|passwd)(\s*[=:]\s*)(\"?)([^\s,;\"]+)(\"?)")
BEARER_RE = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9\-_\.=]{8,}")
SK_RE = re.compile(r"\bsk-[A-Za-z0-9\-_]{12,}")


def redact(text: str) -> str:
    text = BEARER_RE.sub("Bearer [REDACTED]", text)
    text = SECRET_KV_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}[REDACTED]{m.group(5)}", text)
    return SK_RE.sub("[REDACTED]", text)


class RedactingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        redacted = redact(msg)
        if redacted != msg:
            record.msg = redacted
            record.args = ()
        return True


def configure_logging(settings: Settings) -> None:
    settings.ensure_dirs()
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    log_path = settings.logs_dir / "app.log"
    # Replace any previous LGL file handler (e.g. a different data dir in tests); keep a single stream handler.
    for h in list(root.handlers):
        if getattr(h, "_lgl_file", False):
            if Path(getattr(h, "baseFilename", "")) == log_path:
                return
            root.removeHandler(h)
            h.close()
    fh = logging.handlers.RotatingFileHandler(log_path, maxBytes=5_000_000, backupCount=3)
    fh.setFormatter(fmt)
    fh.addFilter(RedactingFilter())
    fh._lgl_file = True  # type: ignore[attr-defined]
    root.addHandler(fh)
    if not any(getattr(h, "_lgl_stream", False) for h in root.handlers):
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        sh.addFilter(RedactingFilter())
        sh._lgl_stream = True  # type: ignore[attr-defined]
        root.addHandler(sh)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
