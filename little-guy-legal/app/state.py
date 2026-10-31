"""Application-wide service container."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from .config import Settings
from .db import Database
from .services.cases import CaseService
from .services.documents import DocumentService

if TYPE_CHECKING:  # pragma: no cover
    from .services.authority import AuthorityService
    from .services.pipeline import PipelineController
    from .services.report import ReportService


@dataclass
class AppState:
    settings: Settings
    db: Database
    cases: CaseService
    documents: DocumentService
    authorities: "AuthorityService"
    pipeline: "PipelineController"
    reports: "ReportService"
    warnings: list[str] = field(default_factory=list)


def build_state(settings: Settings) -> AppState:
    from .services.authority import AuthorityService
    from .services.pipeline import PipelineController
    from .services.report import ReportService

    settings.ensure_dirs()
    db = Database(settings.db_path)
    cases = CaseService(db, settings)
    documents = DocumentService(db, settings)
    authorities = AuthorityService(db, settings)
    authorities.load_library_if_empty()
    reports = ReportService(db, settings, cases, documents, authorities)
    pipeline = PipelineController(db, settings, cases, documents, authorities, reports)
    state = AppState(settings, db, cases, documents, authorities, pipeline, reports)
    state.warnings.extend(pipeline.startup_warnings())
    return state
