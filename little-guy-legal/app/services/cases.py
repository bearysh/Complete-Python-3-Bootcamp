from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from ..config import Settings
from ..db import Database, utcnow
from ..models.case import CaseCreate, CaseOut, IntakeData
from .ids import new_id


class CaseNotFound(LookupError):
    pass


class CaseService:
    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings

    def case_dir(self, case_id: str) -> Path:
        return self.settings.cases_dir / case_id

    def create(self, payload: CaseCreate) -> CaseOut:
        case_id = new_id("case")
        now = utcnow()
        self.db.execute(
            "INSERT INTO cases(id,title,status,jurisdiction,county,matter_type,created_at,updated_at)"
            " VALUES(?,?,?,?,?,?,?,?)",
            (case_id, payload.title.strip(), "intake", "US-TX", payload.county.strip() or "Tarrant", "commercial_lease", now, now),
        )
        for sub in ("originals", "extracted", "reports", "transcripts"):
            (self.case_dir(case_id) / sub).mkdir(parents=True, exist_ok=True)
        self.db.audit(case_id, "case.created", {"title": payload.title})
        return self.get(case_id)

    def _row(self, case_id: str):
        row = self.db.query_one("SELECT * FROM cases WHERE id=?", (case_id,))
        if row is None:
            raise CaseNotFound(case_id)
        return row

    def get(self, case_id: str) -> CaseOut:
        row = self._row(case_id)
        return self._to_out(row)

    def _to_out(self, row) -> CaseOut:
        case_id = row["id"]
        doc_count = self.db.query_one("SELECT COUNT(*) AS n FROM documents WHERE case_id=?", (case_id,))["n"]
        intake = self.db.query_one("SELECT 1 FROM intake WHERE case_id=?", (case_id,))
        run = self.db.query_one(
            "SELECT id,status FROM analysis_runs WHERE case_id=? ORDER BY started_at DESC LIMIT 1", (case_id,)
        )
        report = self.db.query_one(
            "SELECT id,status FROM reports WHERE case_id=? ORDER BY version DESC LIMIT 1", (case_id,)
        )
        return CaseOut(
            id=case_id,
            title=row["title"],
            status=row["status"],
            jurisdiction=row["jurisdiction"],
            county=row["county"],
            matter_type=row["matter_type"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            document_count=doc_count,
            has_intake=intake is not None,
            latest_run_id=run["id"] if run else None,
            latest_run_status=run["status"] if run else None,
            latest_report_id=report["id"] if report else None,
            latest_report_status=report["status"] if report else None,
        )

    def list(self) -> list[CaseOut]:
        rows = self.db.query("SELECT * FROM cases ORDER BY created_at DESC")
        return [self._to_out(r) for r in rows]

    def set_status(self, case_id: str, status: str) -> None:
        self._row(case_id)
        self.db.execute("UPDATE cases SET status=?, updated_at=? WHERE id=?", (status, utcnow(), case_id))

    def delete(self, case_id: str) -> None:
        self._row(case_id)
        self.db.execute("DELETE FROM segments_fts WHERE case_id=?", (case_id,))
        self.db.execute("DELETE FROM cases WHERE id=?", (case_id,))
        shutil.rmtree(self.case_dir(case_id), ignore_errors=True)
        self.db.audit(case_id, "case.deleted")

    # ---- intake -------------------------------------------------------
    def get_intake(self, case_id: str) -> IntakeData | None:
        self._row(case_id)
        row = self.db.query_one("SELECT data_json FROM intake WHERE case_id=?", (case_id,))
        return IntakeData.model_validate_json(row["data_json"]) if row else None

    def save_intake(self, case_id: str, data: IntakeData) -> IntakeData:
        self._row(case_id)
        now = utcnow()
        self.db.execute(
            "INSERT INTO intake(case_id,data_json,updated_at) VALUES(?,?,?)"
            " ON CONFLICT(case_id) DO UPDATE SET data_json=excluded.data_json, updated_at=excluded.updated_at",
            (case_id, data.model_dump_json(), now),
        )
        self.db.execute("UPDATE cases SET updated_at=? WHERE id=?", (now, case_id))
        self.db.audit(case_id, "intake.saved", {"missing": data.missing_essentials()})
        return data

    def audit_trail(self, case_id: str) -> list[dict[str, Any]]:
        rows = self.db.query("SELECT ts,event,detail_json FROM audit_log WHERE case_id=? ORDER BY id", (case_id,))
        return [{"ts": r["ts"], "event": r["event"], "detail": json.loads(r["detail_json"])} for r in rows]
