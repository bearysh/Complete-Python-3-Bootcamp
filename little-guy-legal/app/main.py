"""Little Guy Legal — local FastAPI application."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .api import routes_analysis, routes_cases, routes_reports, routes_system
from .config import Settings, get_settings
from .logging_setup import configure_logging
from .state import build_state

FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings)
    log = logging.getLogger("lgl")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        state = build_state(settings)
        app.state.lgl = state
        for w in state.warnings:
            log.warning(w)
        try:
            cleaned = state.pipeline.cleanup_expired_sessions()
            if cleaned:
                log.info("Cleaned %d expired inference sessions", cleaned)
        except Exception as exc:  # never block startup
            log.warning("Session cleanup skipped: %s", type(exc).__name__)
        log.info("Little Guy Legal ready at http://%s:%d (data: %s)", settings.host, settings.port, settings.data_dir)
        yield
        state.db.close()

    app = FastAPI(title="Little Guy Legal", version="0.1.0", lifespan=lifespan, docs_url="/api/docs", redoc_url=None)
    app.include_router(routes_system.router)
    app.include_router(routes_cases.router)
    app.include_router(routes_analysis.router)
    app.include_router(routes_reports.router)

    if FRONTEND_DIR.is_dir():
        app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")

        @app.get("/", include_in_schema=False)
        @app.get("/cases/{path:path}", include_in_schema=False)
        def index(path: str = "") -> FileResponse:
            return FileResponse(FRONTEND_DIR / "index.html")

    return app


app = create_app()
