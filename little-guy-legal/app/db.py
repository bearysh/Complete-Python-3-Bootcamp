"""SQLite persistence. The database is the authoritative source of case state."""
from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

SCHEMA_VERSION = 1

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS cases (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'intake',
  jurisdiction TEXT NOT NULL DEFAULT 'US-TX',
  county TEXT NOT NULL DEFAULT 'Tarrant',
  matter_type TEXT NOT NULL DEFAULT 'commercial_lease',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS documents (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  filename TEXT NOT NULL,
  stored_path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  mime TEXT NOT NULL,
  doc_kind TEXT NOT NULL DEFAULT 'unknown',
  size_bytes INTEGER NOT NULL,
  uploaded_at TEXT NOT NULL,
  extraction_status TEXT NOT NULL DEFAULT 'pending',
  extraction_error TEXT,
  page_count INTEGER,
  segment_count INTEGER,
  unreadable_pages TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_documents_case ON documents(case_id);

CREATE TABLE IF NOT EXISTS segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  case_id TEXT NOT NULL,
  ref TEXT NOT NULL,
  locator_type TEXT NOT NULL,
  page_number INTEGER,
  paragraph_index INTEGER,
  section_label TEXT,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_segments_doc ON segments(document_id);
CREATE INDEX IF NOT EXISTS idx_segments_ref ON segments(case_id, ref);

CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
  text, case_id UNINDEXED, segment_id UNINDEXED, tokenize='porter unicode61'
);

CREATE TABLE IF NOT EXISTS intake (
  case_id TEXT PRIMARY KEY REFERENCES cases(id) ON DELETE CASCADE,
  data_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS analysis_runs (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  current_stage TEXT,
  provider TEXT NOT NULL,
  model TEXT,
  argument_style TEXT NOT NULL DEFAULT 'by_the_book',
  started_at TEXT NOT NULL,
  finished_at TEXT,
  error TEXT,
  cancel_requested INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_runs_case ON analysis_runs(case_id);

CREATE TABLE IF NOT EXISTS stage_executions (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
  case_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 1,
  session_id TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  duration_ms INTEGER,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  output_json TEXT,
  error TEXT,
  raw_response_path TEXT,
  session_cleaned INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_stage_run ON stage_executions(run_id);

CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  status TEXT NOT NULL,
  json_path TEXT NOT NULL,
  pdf_path TEXT,
  created_at TEXT NOT NULL,
  reviewed_at TEXT,
  reviewer TEXT,
  reviewer_action TEXT,
  reviewer_note TEXT,
  acknowledged_failures INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reports_case ON reports(case_id);

CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  case_id TEXT,
  ts TEXT NOT NULL,
  event TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_audit_case ON audit_log(case_id);

CREATE TABLE IF NOT EXISTS authorities (
  id TEXT PRIMARY KEY,
  citation TEXT NOT NULL,
  title TEXT NOT NULL,
  jurisdiction TEXT NOT NULL,
  authority_type TEXT NOT NULL,
  binding_scope TEXT NOT NULL,
  source_url TEXT NOT NULL,
  retrieved_at TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  text TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE VIRTUAL TABLE IF NOT EXISTS authorities_fts USING fts5(
  citation, title, text, authority_id UNINDEXED, tokenize='porter unicode61'
);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Database:
    """Thin wrapper around sqlite3 with per-thread connections."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._local = threading.local()
        self._init_lock = threading.Lock()
        self.initialize()

    def _connect(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, timeout=30, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys=ON")
            self._local.conn = conn
        return conn

    def initialize(self) -> None:
        with self._init_lock:
            conn = self._connect()
            conn.executescript(SCHEMA)
            conn.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            conn.commit()

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise

    def query(self, sql: str, params: tuple | dict = ()) -> list[sqlite3.Row]:
        return self._connect().execute(sql, params).fetchall()

    def query_one(self, sql: str, params: tuple | dict = ()) -> sqlite3.Row | None:
        return self._connect().execute(sql, params).fetchone()

    def execute(self, sql: str, params: tuple | dict = ()) -> None:
        with self.tx() as conn:
            conn.execute(sql, params)

    def audit(self, case_id: str | None, event: str, detail: dict[str, Any] | None = None) -> None:
        self.execute(
            "INSERT INTO audit_log(case_id, ts, event, detail_json) VALUES(?,?,?,?)",
            (case_id, utcnow(), event, json.dumps(detail or {}, default=str)),
        )

    def close(self) -> None:
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            conn.close()
            self._local.conn = None


def row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None
