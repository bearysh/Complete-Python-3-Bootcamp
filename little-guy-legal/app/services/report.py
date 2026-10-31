"""Report assembly (machine-readable JSON) and PDF rendering.

A report is created as a *draft* at the end of a run. It becomes *approved* or
*rejected* only through an explicit reviewer action recorded with a timestamp.
The PDF states the review status on every page.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ..config import Settings
from ..db import Database, utcnow
from .authority import AuthorityService
from .cases import CaseService
from .documents import DocumentService
from .ids import new_id

REPORT_TITLE = "Little Guy Legal — Case Research Report"
REPORT_LABEL = "AI-Assisted Legal Research — For Attorney Review"
SCOPE_LIMITATIONS = [
    "This report was produced by software using locally hosted AI models and is not legal advice. Little Guy Legal is not a law firm and does not represent any party.",
    "No licensed attorney has reviewed this report unless a separate attorney review is expressly documented. Approval by the operator confirms only that the report was reviewed for completeness and obvious errors.",
    "Legal authorities are drawn from a local library of Texas statutes. Verification confirms citations match stored text; it does not confirm that an authority is current, remains good law, or governs these facts.",
    "Statements are classified as documented facts, user allegations, inferences, or unverified claims. Unverified items should be treated as open questions for counsel.",
    "The analysis does not predict the outcome of any dispute and does not estimate probabilities of success.",
]


class ReportService:
    def __init__(self, db: Database, settings: Settings, cases: CaseService, documents: DocumentService, authorities: AuthorityService):
        self.db = db
        self.settings = settings
        self.cases = cases
        self.documents = documents
        self.authorities = authorities

    # ---- creation --------------------------------------------------------
    def create_draft(self, case_id: str, run_id: str, outputs: dict[str, Any]) -> dict[str, Any]:
        version_row = self.db.query_one("SELECT COALESCE(MAX(version),0)+1 AS v FROM reports WHERE case_id=?", (case_id,))
        version = int(version_row["v"])
        report_id = new_id("rpt")
        data = self.assemble(case_id, run_id, outputs, report_id, version)
        rdir = self.settings.cases_dir / case_id / "reports"
        rdir.mkdir(parents=True, exist_ok=True)
        json_path = rdir / f"report_v{version}.json"
        pdf_path = rdir / f"report_v{version}_draft.pdf"
        json_path.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str))
        from .pdf import render_pdf

        render_pdf(data, pdf_path)
        self.db.execute(
            "INSERT INTO reports(id,case_id,run_id,version,status,json_path,pdf_path,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (report_id, case_id, run_id, version, "draft", str(json_path), str(pdf_path), utcnow()),
        )
        self.db.audit(case_id, "report.draft_created", {"report_id": report_id, "version": version})
        return {"report_id": report_id, "version": version, "json_path": str(json_path), "pdf_path": str(pdf_path),
                "material_verification_failure": data["verification"]["material_failure"]}

    def assemble(self, case_id: str, run_id: str, outputs: dict[str, Any], report_id: str, version: int) -> dict[str, Any]:
        case = self.cases.get(case_id)
        intake = self.cases.get_intake(case_id)
        docs = self.documents.list(case_id)
        run = self.db.query_one("SELECT * FROM analysis_runs WHERE id=?", (run_id,))
        stages = self.db.query("SELECT stage,status,attempt,duration_ms,prompt_tokens,completion_tokens,session_id,finished_at FROM stage_executions WHERE run_id=? AND status='completed' ORDER BY started_at", (run_id,))
        knowledge = outputs.get("knowledge", {})
        verification = outputs.get("verification", {"checks": [], "summary": {}, "material_failure": True, "notes": ["Verification did not run."], "limitations": []})
        # Evidence appendix: every distinct ref with its resolved source excerpt and verification status.
        status_by_ref: dict[str, str] = {}
        for c in verification.get("checks", []):
            if c.get("ref"):
                prev = status_by_ref.get(c["ref"])
                status_by_ref[c["ref"]] = c["status"] if prev in (None, "verified") else prev
        appendix = []
        for ref in sorted(status_by_ref):
            entry: dict[str, Any] = {"ref": ref, "verification_status": status_by_ref[ref]}
            if ref.startswith("D"):
                seg = self.documents.resolve_ref(case_id, ref)
                if seg:
                    doc = next((d for d in docs if d.id == seg.document_id), None)
                    entry.update({"document": doc.filename if doc else None, "location": seg.ref, "section": seg.section_label,
                                  "excerpt": seg.text[:700] + ("…" if len(seg.text) > 700 else "")})
                else:
                    entry["excerpt"] = "(reference did not resolve to a stored passage)"
            elif ref.startswith("A:"):
                auth = self.authorities.get(ref[2:])
                if auth:
                    entry.update({"citation": auth["citation"], "title": auth["title"], "source_url": auth["source_url"],
                                  "retrieved_at": auth["retrieved_at"], "sha256": auth["sha256"], "excerpt": auth["text"][:700]})
                else:
                    entry["excerpt"] = "(authority id is not in the local library — rejected)"
            appendix.append(entry)
        authorities_used = []
        for a in knowledge.get("candidate_authorities", []):
            auth = self.authorities.get(a.get("authority_id", "")) if a.get("authority_id") not in (None, "", "none") else None
            authorities_used.append({**a, "verified_in_library": auth is not None,
                                     "library_citation": auth["citation"] if auth else None, "source_url": auth["source_url"] if auth else None,
                                     "retrieved_at": auth["retrieved_at"] if auth else None})
        provider_real = bool(run["provider"] in ("hermes", "omlx"))
        return {
            "report_id": report_id,
            "version": version,
            "title": REPORT_TITLE,
            "label": REPORT_LABEL,
            "generated_at": utcnow(),
            "review": {"status": "draft", "reviewed_at": None, "reviewer": None, "action": None, "note": None, "acknowledged_verification_failures": False},
            "case": case.model_dump(),
            "intake": intake.model_dump() if intake else None,
            "documents": [d.model_dump() for d in docs],
            "scope_and_limitations": SCOPE_LIMITATIONS + ([] if provider_real else [
                "TEST FIXTURE: this report was generated with the scripted test provider. Its analytical content is canned test data, not model output."]),
            "executive_summary": outputs.get("senior_partner", {}).get("executive_summary", "(not produced)"),
            "background_and_timeline": {"facts": knowledge.get("facts", []), "timeline": knowledge.get("timeline", []), "parties": knowledge.get("parties", [])},
            "key_lease_provisions": knowledge.get("key_provisions", []),
            "legal_authorities": authorities_used,
            "main_legal_issues": outputs.get("senior_partner", {}).get("main_issues", []),
            "legal_questions": knowledge.get("legal_questions", []),
            "customer_arguments": outputs.get("advocate_customer", {}),
            "opposing_arguments": outputs.get("advocate_opposing", {}),
            "skeptical_analysis": outputs.get("judge", {}),
            "missing_information": sorted(set(knowledge.get("missing_information", []) + outputs.get("senior_partner", {}).get("information_gaps", []))),
            "time_sensitive_concerns": outputs.get("senior_partner", {}).get("time_sensitive_concerns", []),
            "practical_considerations": outputs.get("senior_partner", {}).get("practical_considerations", []),
            "questions_for_attorney": outputs.get("senior_partner", {}).get("questions_for_attorney", []),
            "unverified_claims": outputs.get("senior_partner", {}).get("unverified_claims", []),
            "caveats": knowledge.get("caveats", []),
            "verification": verification,
            "evidence_appendix": appendix,
            "metadata": {
                "run_id": run_id,
                "provider": run["provider"],
                "provider_is_real_inference": provider_real,
                "model": run["model"],
                "argument_style": run["argument_style"],
                "stages": [dict(s) for s in stages],
                "authority_library_size": len(self.authorities.list()),
                "software": "Little Guy Legal Milestone 1",
            },
        }

    # ---- review ----------------------------------------------------------
    def get(self, case_id: str, report_id: str) -> dict[str, Any]:
        row = self.db.query_one("SELECT * FROM reports WHERE id=? AND case_id=?", (report_id, case_id))
        if row is None:
            raise LookupError("report not found")
        return dict(row)

    def list(self, case_id: str) -> list[dict[str, Any]]:
        return [dict(r) for r in self.db.query("SELECT * FROM reports WHERE case_id=? ORDER BY version DESC", (case_id,))]

    def load_json(self, case_id: str, report_id: str) -> dict[str, Any]:
        row = self.get(case_id, report_id)
        return json.loads(Path(row["json_path"]).read_text())

    def review(self, case_id: str, report_id: str, action: str, reviewer: str, note: str, acknowledge_failures: bool) -> dict[str, Any]:
        row = self.get(case_id, report_id)
        if row["status"] != "draft":
            raise ValueError(f"Report is already {row['status']}; create a new analysis run for a new draft.")
        if action not in ("approve", "reject"):
            raise ValueError("action must be 'approve' or 'reject'")
        data = self.load_json(case_id, report_id)
        if action == "approve" and data["verification"].get("material_failure") and not acknowledge_failures:
            raise PermissionError("Material verification failures are unresolved. Approval requires explicit acknowledgement.")
        if not reviewer.strip():
            raise ValueError("reviewer name is required")
        now = utcnow()
        status = "approved" if action == "approve" else "rejected"
        data["review"] = {"status": status, "reviewed_at": now, "reviewer": reviewer.strip()[:120], "action": action, "note": note[:2000],
                          "acknowledged_verification_failures": bool(acknowledge_failures)}
        json_path = Path(row["json_path"])
        json_path.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str))
        pdf_path = json_path.with_name(f"report_v{row['version']}_{status}.pdf")
        from .pdf import render_pdf

        render_pdf(data, pdf_path)
        self.db.execute(
            "UPDATE reports SET status=?, pdf_path=?, reviewed_at=?, reviewer=?, reviewer_action=?, reviewer_note=?, acknowledged_failures=? WHERE id=?",
            (status, str(pdf_path), now, reviewer.strip()[:120], action, note[:2000], int(acknowledge_failures), report_id),
        )
        self.cases.set_status(case_id, "report_approved" if status == "approved" else "report_rejected")
        self.db.audit(case_id, f"report.{status}", {"report_id": report_id, "reviewer": reviewer.strip()[:120], "acknowledged_failures": bool(acknowledge_failures)})
        return self.get(case_id, report_id)
