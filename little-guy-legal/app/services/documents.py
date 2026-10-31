from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from pathlib import Path

from ..config import Settings
from ..db import Database, utcnow
from ..models.case import DocumentOut, SegmentOut
from .cases import CaseNotFound
from .extraction import UnsupportedFileError, extract, guess_doc_kind, sniff_mime
from .ids import new_id

MAX_UPLOAD_BYTES = 50 * 1024 * 1024
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._\- ]+")


class DocumentNotFound(LookupError):
    pass


def protect_original(path: Path) -> None:
    """Make an uploaded original read-only. On macOS/BSD also set the user-immutable flag,
    which blocks writes even by the owning user until the flag is cleared."""
    path.chmod(stat.S_IRUSR | stat.S_IRGRP)
    if hasattr(os, "chflags") and hasattr(stat, "UF_IMMUTABLE"):
        try:
            os.chflags(path, stat.UF_IMMUTABLE)  # type: ignore[attr-defined]
        except OSError:
            pass


def unprotect_original(path: Path) -> None:
    if hasattr(os, "chflags"):
        try:
            os.chflags(path, 0)  # type: ignore[attr-defined]
        except OSError:
            pass
    try:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def safe_filename(name: str) -> str:
    base = os.path.basename(name.replace("\\", "/")).strip() or "document"
    base = SAFE_NAME_RE.sub("_", base)[:120]
    if base.startswith("."):
        base = "_" + base
    return base


class DocumentService:
    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings

    def _case_exists(self, case_id: str) -> None:
        if self.db.query_one("SELECT 1 FROM cases WHERE id=?", (case_id,)) is None:
            raise CaseNotFound(case_id)

    def _originals_dir(self, case_id: str) -> Path:
        p = self.settings.cases_dir / case_id / "originals"
        p.mkdir(parents=True, exist_ok=True)
        return p

    def _extracted_dir(self, case_id: str) -> Path:
        p = self.settings.cases_dir / case_id / "extracted"
        p.mkdir(parents=True, exist_ok=True)
        return p

    def store_and_extract(self, case_id: str, filename: str, content: bytes, doc_kind: str | None = None) -> DocumentOut:
        self._case_exists(case_id)
        if len(content) > MAX_UPLOAD_BYTES:
            raise UnsupportedFileError("File exceeds the 50 MB upload limit.")
        if len(content) == 0:
            raise UnsupportedFileError("Empty file.")
        doc_id = new_id("doc")
        fname = safe_filename(filename)
        if not fname.lower().endswith((".pdf", ".docx")):
            raise UnsupportedFileError("Only .pdf and .docx files are accepted.")
        target = self._originals_dir(case_id) / f"{doc_id}__{fname}"
        target.write_bytes(content)
        protect_original(target)
        try:
            mime = sniff_mime(target)
        except UnsupportedFileError:
            unprotect_original(target)
            target.unlink(missing_ok=True)
            raise
        sha = hashlib.sha256(content).hexdigest()
        ordinal_row = self.db.query_one("SELECT COALESCE(MAX(ordinal),0)+1 AS n FROM documents WHERE case_id=?", (case_id,))
        ordinal = int(ordinal_row["n"])
        now = utcnow()
        self.db.execute(
            "INSERT INTO documents(id,case_id,ordinal,filename,stored_path,sha256,mime,doc_kind,size_bytes,uploaded_at,extraction_status)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (doc_id, case_id, ordinal, fname, str(target), sha, mime, doc_kind or "unknown", len(content), now, "pending"),
        )
        self.db.audit(case_id, "document.uploaded", {"document_id": doc_id, "filename": fname, "sha256": sha})
        self._extract(case_id, doc_id, ordinal, target, mime, fname, doc_kind)
        return self.get(case_id, doc_id)

    def _extract(self, case_id: str, doc_id: str, ordinal: int, path: Path, mime: str, fname: str, doc_kind: str | None) -> None:
        try:
            result = extract(path, mime)
        except Exception as exc:  # extraction failures are recorded, never raised to the uploader
            self.db.execute(
                "UPDATE documents SET extraction_status='failed', extraction_error=? WHERE id=?",
                (f"{type(exc).__name__}: {exc}"[:500], doc_id),
            )
            self.db.audit(case_id, "document.extraction_failed", {"document_id": doc_id, "error": type(exc).__name__})
            return
        kind = doc_kind or guess_doc_kind(fname, result.full_text)
        with self.db.tx() as conn:
            for seg in result.segments:
                ref = seg.ref(ordinal)
                cur = conn.execute(
                    "INSERT INTO segments(document_id,case_id,ref,locator_type,page_number,paragraph_index,section_label,text)"
                    " VALUES(?,?,?,?,?,?,?,?)",
                    (doc_id, case_id, ref, seg.locator_type, seg.page_number, seg.paragraph_index, seg.section_label, seg.text),
                )
                conn.execute(
                    "INSERT INTO segments_fts(text, case_id, segment_id) VALUES(?,?,?)",
                    (seg.text, case_id, cur.lastrowid),
                )
            conn.execute(
                "UPDATE documents SET extraction_status='extracted', page_count=?, segment_count=?, unreadable_pages=?,"
                " doc_kind=?, metadata_json=? WHERE id=?",
                (
                    result.page_count,
                    len(result.segments),
                    json.dumps(result.unreadable_pages),
                    kind,
                    json.dumps({"warnings": result.warnings, "ocr_used": result.ocr_used}),
                    doc_id,
                ),
            )
        # Extracted text is also persisted as a file for inspection and backup.
        out = self._extracted_dir(case_id) / f"{doc_id}.json"
        out.write_text(
            json.dumps(
                {
                    "document_id": doc_id,
                    "ref_prefix": f"D{ordinal}",
                    "filename": fname,
                    "segments": [
                        {"ref": s.ref(ordinal), "section": s.section_label, "text": s.text} for s in result.segments
                    ],
                    "warnings": result.warnings,
                },
                indent=1,
            )
        )
        self.db.audit(case_id, "document.extracted", {"document_id": doc_id, "segments": len(result.segments)})

    def _to_out(self, row) -> DocumentOut:
        return DocumentOut(
            id=row["id"],
            case_id=row["case_id"],
            ordinal=row["ordinal"],
            ref_prefix=f"D{row['ordinal']}",
            filename=row["filename"],
            mime=row["mime"],
            doc_kind=row["doc_kind"],
            size_bytes=row["size_bytes"],
            sha256=row["sha256"],
            uploaded_at=row["uploaded_at"],
            extraction_status=row["extraction_status"],
            extraction_error=row["extraction_error"],
            page_count=row["page_count"],
            segment_count=row["segment_count"],
            unreadable_pages=json.loads(row["unreadable_pages"] or "[]"),
        )

    def list(self, case_id: str) -> list[DocumentOut]:
        self._case_exists(case_id)
        rows = self.db.query("SELECT * FROM documents WHERE case_id=? ORDER BY ordinal", (case_id,))
        return [self._to_out(r) for r in rows]

    def get(self, case_id: str, doc_id: str) -> DocumentOut:
        row = self.db.query_one("SELECT * FROM documents WHERE id=? AND case_id=?", (doc_id, case_id))
        if row is None:
            raise DocumentNotFound(doc_id)
        return self._to_out(row)

    def set_kind(self, case_id: str, doc_id: str, kind: str) -> DocumentOut:
        self.get(case_id, doc_id)
        self.db.execute("UPDATE documents SET doc_kind=? WHERE id=?", (kind, doc_id))
        return self.get(case_id, doc_id)

    def delete(self, case_id: str, doc_id: str) -> None:
        doc = self.get(case_id, doc_id)
        path = Path(self.db.query_one("SELECT stored_path FROM documents WHERE id=?", (doc_id,))["stored_path"])
        self.db.execute("DELETE FROM segments_fts WHERE segment_id IN (SELECT id FROM segments WHERE document_id=?)", (doc_id,))
        self.db.execute("DELETE FROM documents WHERE id=?", (doc_id,))
        if path.exists():
            unprotect_original(path)
            path.unlink()
        (self._extracted_dir(case_id) / f"{doc_id}.json").unlink(missing_ok=True)
        self.db.audit(case_id, "document.deleted", {"document_id": doc_id, "filename": doc.filename})

    def original_path(self, case_id: str, doc_id: str) -> Path:
        self.get(case_id, doc_id)
        return Path(self.db.query_one("SELECT stored_path FROM documents WHERE id=?", (doc_id,))["stored_path"])

    # ---- segments ------------------------------------------------------
    def segments(self, case_id: str, doc_id: str) -> list[SegmentOut]:
        self.get(case_id, doc_id)
        rows = self.db.query("SELECT * FROM segments WHERE document_id=? ORDER BY id", (doc_id,))
        return [SegmentOut(**dict(r)) for r in rows]

    def resolve_ref(self, case_id: str, ref: str) -> SegmentOut | None:
        """Resolve ``D{n}:p{page}`` / ``D{n}:para{idx}`` within a single case only."""
        row = self.db.query_one("SELECT * FROM segments WHERE case_id=? AND ref=?", (case_id, ref))
        return SegmentOut(**dict(row)) if row else None

    def search(self, case_id: str, query: str, limit: int = 20) -> list[dict]:
        self._case_exists(case_id)
        q = _fts_query(query)
        if not q:
            return []
        rows = self.db.query(
            "SELECT s.id, s.ref, s.document_id, s.section_label, snippet(segments_fts, 0, '[', ']', '…', 24) AS snippet"
            " FROM segments_fts f JOIN segments s ON s.id = f.segment_id"
            " WHERE segments_fts MATCH ? AND f.case_id=? ORDER BY bm25(segments_fts) LIMIT ?",
            (q, case_id, limit),
        )
        return [dict(r) for r in rows]


def _fts_query(text: str) -> str:
    """Turn free text into a safe FTS5 query of quoted terms."""
    terms = re.findall(r"[A-Za-z0-9][A-Za-z0-9'\.\-]{1,40}", text)
    return " ".join(f'"{t}"' for t in terms[:12])
