"""Deterministic workflow controller: a durable, explicit state machine.

Stages run strictly in order, each stage persists its output before the next
begins, and a run can be resumed after failure or restart without redoing
completed stages. Exactly one run executes at a time (one local inference at a
time).
"""
from __future__ import annotations

import json
import logging
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from ..config import Settings
from ..db import Database, utcnow
from ..inference.base import CancelToken, InferenceCancelled, InferenceError, InferenceProvider, InferenceRequest
from ..inference.factory import build_provider
from ..inference.json_utils import StructuredOutputError, parse_model
from ..models.case import IntakeData
from ..models.stages import STAGE_SCHEMAS, ArgumentOutput, ArgumentStyle, JudgeOutput, KnowledgeOutput, SeniorPartnerOutput
from . import prompts
from .authority import AuthorityService
from .cases import CaseService
from .documents import DocumentService
from .ids import new_id
from .verification import VerificationService

log = logging.getLogger("lgl.pipeline")

STAGES = ["extraction_check", "knowledge", "advocate_customer", "advocate_opposing", "judge", "senior_partner", "verification", "report_draft"]
MODEL_STAGES = {"knowledge", "advocate_customer", "advocate_opposing", "judge", "senior_partner"}
STAGE_LABELS = {
    "extraction_check": "Document extraction check",
    "knowledge": "Knowledge Specialist",
    "advocate_customer": "Customer Advocate",
    "advocate_opposing": "Opposing Litigator",
    "judge": "Skeptical Reviewer",
    "senior_partner": "Senior Partner synthesis",
    "verification": "Independent verification",
    "report_draft": "Draft report",
}
MAX_REPAIR_ATTEMPTS = 2


class PipelineError(RuntimeError):
    pass


class PipelineController:
    def __init__(self, db: Database, settings: Settings, cases: CaseService, documents: DocumentService,
                 authorities: AuthorityService, reports: "Any"):
        self.db = db
        self.settings = settings
        self.cases = cases
        self.documents = documents
        self.authorities = authorities
        self.reports = reports
        self.verifier = VerificationService(documents, authorities)
        self._provider: InferenceProvider | None = None
        self._provider_error: str | None = None
        self._lock = threading.Lock()
        self._active: dict[str, tuple[threading.Thread, CancelToken]] = {}
        self._init_provider()
        self._mark_interrupted_runs()

    # ---- provider ----------------------------------------------------
    def _init_provider(self) -> None:
        try:
            self._provider = build_provider(self.settings)
        except InferenceError as exc:
            self._provider = None
            self._provider_error = str(exc)
            log.error("Inference provider unavailable: %s", exc)

    @property
    def provider(self) -> InferenceProvider:
        if self._provider is None:
            raise PipelineError(self._provider_error or "Inference provider not configured.")
        return self._provider

    def provider_status(self) -> dict[str, Any]:
        if self._provider is None:
            return {"configured": False, "error": self._provider_error, "provider": self.settings.inference_provider}
        info = self._provider.info
        return {"configured": True, "provider": info.name, "label": info.label, "endpoint": info.endpoint, "model": info.model,
                "is_real_inference": info.is_real_inference, "notes": info.notes}

    def provider_health(self) -> dict[str, Any]:
        if self._provider is None:
            return {"ok": False, "detail": self._provider_error}
        try:
            return self._provider.health()
        except Exception as exc:  # health must never raise
            return {"ok": False, "detail": f"{type(exc).__name__}: {exc}"}

    def startup_warnings(self) -> list[str]:
        w = []
        if self._provider is None:
            w.append(f"Inference provider not available: {self._provider_error}")
        elif not self._provider.info.is_real_inference:
            w.append("SCRIPTED TEST PROVIDER ACTIVE: analysis outputs are canned fixtures, not model output. Never use for a real case.")
        return w

    # ---- startup recovery --------------------------------------------
    def _mark_interrupted_runs(self) -> None:
        rows = self.db.query("SELECT id, case_id FROM analysis_runs WHERE status IN ('running','queued')")
        for r in rows:
            self.db.execute("UPDATE analysis_runs SET status='interrupted', error=? WHERE id=?",
                            ("Application restarted while the analysis was running. Resume to continue from the last completed stage.", r["id"]))
            self.db.execute("UPDATE stage_executions SET status='failed', finished_at=?, error='interrupted by restart' WHERE run_id=? AND status='running'",
                            (utcnow(), r["id"]))
            self.db.audit(r["case_id"], "run.interrupted", {"run_id": r["id"]})

    # ---- public API --------------------------------------------------
    def is_running(self, case_id: str) -> bool:
        with self._lock:
            entry = self._active.get(case_id)
            return bool(entry and entry[0].is_alive())

    def start(self, case_id: str, argument_style: ArgumentStyle = "by_the_book") -> dict[str, Any]:
        self.cases.get(case_id)
        provider = self.provider  # raises actionable error if unavailable
        if self.is_running(case_id):
            raise PipelineError("An analysis is already running for this case.")
        docs = [d for d in self.documents.list(case_id) if d.extraction_status == "extracted"]
        if not docs:
            raise PipelineError("Upload at least one document with extracted text before starting analysis.")
        if argument_style == "maximum_challenge":
            raise PipelineError("The 'Maximum Challenge' style is deferred to a later milestone.")
        run_id = new_id("run")
        self.db.execute(
            "INSERT INTO analysis_runs(id,case_id,status,current_stage,provider,model,argument_style,started_at) VALUES(?,?,?,?,?,?,?,?)",
            (run_id, case_id, "queued", STAGES[0], provider.info.name, provider.info.model, argument_style, utcnow()),
        )
        self.cases.set_status(case_id, "analyzing")
        self.db.audit(case_id, "run.started", {"run_id": run_id, "provider": provider.info.name, "style": argument_style})
        self._launch(case_id, run_id)
        return self.get_run(case_id, run_id)

    def resume(self, case_id: str, run_id: str) -> dict[str, Any]:
        run = self._run_row(case_id, run_id)
        if run["status"] in ("running", "queued") and self.is_running(case_id):
            raise PipelineError("Run is already in progress.")
        if run["status"] == "completed":
            raise PipelineError("Run already completed.")
        self.provider
        self.db.execute("UPDATE analysis_runs SET status='queued', error=NULL, cancel_requested=0, finished_at=NULL WHERE id=?", (run_id,))
        self.cases.set_status(case_id, "analyzing")
        self.db.audit(case_id, "run.resumed", {"run_id": run_id})
        self._launch(case_id, run_id)
        return self.get_run(case_id, run_id)

    def cancel(self, case_id: str, run_id: str) -> dict[str, Any]:
        self._run_row(case_id, run_id)
        self.db.execute("UPDATE analysis_runs SET cancel_requested=1 WHERE id=?", (run_id,))
        with self._lock:
            entry = self._active.get(case_id)
        if entry:
            entry[1].cancel()
        else:
            self.db.execute("UPDATE analysis_runs SET status='cancelled', finished_at=? WHERE id=? AND status IN ('queued','running','interrupted')",
                            (utcnow(), run_id))
        self.db.audit(case_id, "run.cancel_requested", {"run_id": run_id})
        return self.get_run(case_id, run_id)

    def get_run(self, case_id: str, run_id: str) -> dict[str, Any]:
        run = dict(self._run_row(case_id, run_id))
        stages = self.db.query("SELECT stage,status,attempt,started_at,finished_at,duration_ms,prompt_tokens,completion_tokens,error,session_id"
                               " FROM stage_executions WHERE run_id=? ORDER BY started_at", (run_id,))
        latest: dict[str, dict] = {}
        for s in stages:
            latest[s["stage"]] = dict(s)
        run["stages"] = [{"stage": st, "label": STAGE_LABELS[st], **(latest.get(st) or {"status": "pending"})} for st in STAGES]
        run.pop("cancel_requested", None)
        return run

    def latest_run(self, case_id: str) -> dict[str, Any] | None:
        row = self.db.query_one("SELECT id FROM analysis_runs WHERE case_id=? ORDER BY started_at DESC LIMIT 1", (case_id,))
        return self.get_run(case_id, row["id"]) if row else None

    def list_runs(self, case_id: str) -> list[dict[str, Any]]:
        rows = self.db.query("SELECT id,status,current_stage,provider,model,argument_style,started_at,finished_at,error FROM analysis_runs WHERE case_id=? ORDER BY started_at DESC", (case_id,))
        return [dict(r) for r in rows]

    def stage_outputs(self, case_id: str, run_id: str) -> dict[str, Any]:
        rows = self.db.query("SELECT stage, output_json FROM stage_executions WHERE run_id=? AND case_id=? AND status='completed' AND output_json IS NOT NULL ORDER BY started_at",
                             (run_id, case_id))
        return {r["stage"]: json.loads(r["output_json"]) for r in rows}

    # ---- internals ---------------------------------------------------
    def _run_row(self, case_id: str, run_id: str):
        row = self.db.query_one("SELECT * FROM analysis_runs WHERE id=? AND case_id=?", (run_id, case_id))
        if row is None:
            raise PipelineError("Run not found for this case.")
        return row

    def _launch(self, case_id: str, run_id: str) -> None:
        token = CancelToken()
        thread = threading.Thread(target=self._worker, args=(case_id, run_id, token), name=f"lgl-run-{run_id[-6:]}", daemon=True)
        with self._lock:
            self._active[case_id] = (thread, token)
        thread.start()

    def wait(self, case_id: str, timeout: float | None = None) -> None:
        with self._lock:
            entry = self._active.get(case_id)
        if entry:
            entry[0].join(timeout)

    def _worker(self, case_id: str, run_id: str, cancel: CancelToken) -> None:
        try:
            self.db.execute("UPDATE analysis_runs SET status='running' WHERE id=?", (run_id,))
            completed = self.stage_outputs(case_id, run_id)
            run = self._run_row(case_id, run_id)
            style: ArgumentStyle = run["argument_style"]
            ctx: dict[str, Any] = {"outputs": completed}
            for stage in STAGES:
                if cancel.cancelled:
                    raise InferenceCancelled("Cancelled by operator.")
                self.db.execute("UPDATE analysis_runs SET current_stage=? WHERE id=?", (stage, run_id))
                if stage in completed and stage != "report_draft":
                    continue
                self._execute_stage(case_id, run_id, stage, style, ctx, cancel)
            self.db.execute("UPDATE analysis_runs SET status='completed', finished_at=?, current_stage=NULL WHERE id=?", (utcnow(), run_id))
            self.cases.set_status(case_id, "report_draft")
            self.db.audit(case_id, "run.completed", {"run_id": run_id})
        except InferenceCancelled:
            self.db.execute("UPDATE analysis_runs SET status='cancelled', finished_at=? WHERE id=?", (utcnow(), run_id))
            self.cases.set_status(case_id, "intake")
            self.db.audit(case_id, "run.cancelled", {"run_id": run_id})
        except Exception as exc:
            msg = f"{type(exc).__name__}: {exc}"[:1000]
            log.exception("Run %s failed", run_id)
            self.db.execute("UPDATE analysis_runs SET status='failed', finished_at=?, error=? WHERE id=?", (utcnow(), msg, run_id))
            self.cases.set_status(case_id, "intake")
            self.db.audit(case_id, "run.failed", {"run_id": run_id, "error": type(exc).__name__})
        finally:
            with self._lock:
                self._active.pop(case_id, None)

    def _execute_stage(self, case_id: str, run_id: str, stage: str, style: ArgumentStyle, ctx: dict[str, Any], cancel: CancelToken) -> None:
        exec_id = new_id("stg")
        session_id = f"lgl-{case_id[-8:]}-{stage}-{secrets.token_hex(8)}" if stage in MODEL_STAGES else None
        started = time.monotonic()
        self.db.execute(
            "INSERT INTO stage_executions(id,run_id,case_id,stage,status,attempt,session_id,started_at) VALUES(?,?,?,?,?,?,?,?)",
            (exec_id, run_id, case_id, stage, "running", 1, session_id, utcnow()),
        )
        try:
            if stage == "extraction_check":
                output = self._extraction_check(case_id)
                usage = {}
            elif stage in MODEL_STAGES:
                output, usage = self._run_model_stage(case_id, run_id, stage, style, ctx, session_id, cancel)
            elif stage == "verification":
                report = self.verifier.verify(run_id, case_id, ctx["outputs"])
                output, usage = report.model_dump(), {}
            elif stage == "report_draft":
                output, usage = self.reports.create_draft(case_id, run_id, ctx["outputs"]), {}
            else:  # pragma: no cover
                raise PipelineError(f"Unknown stage {stage}")
        except InferenceCancelled:
            self.db.execute("UPDATE stage_executions SET status='cancelled', finished_at=?, duration_ms=? WHERE id=?",
                            (utcnow(), int((time.monotonic() - started) * 1000), exec_id))
            raise
        except Exception as exc:
            self.db.execute("UPDATE stage_executions SET status='failed', finished_at=?, duration_ms=?, error=? WHERE id=?",
                            (utcnow(), int((time.monotonic() - started) * 1000), f"{type(exc).__name__}: {exc}"[:1000], exec_id))
            raise
        ctx["outputs"][stage] = output
        self.db.execute(
            "UPDATE stage_executions SET status='completed', finished_at=?, duration_ms=?, prompt_tokens=?, completion_tokens=?, output_json=?, attempt=? WHERE id=?",
            (utcnow(), int((time.monotonic() - started) * 1000), usage.get("prompt_tokens"), usage.get("completion_tokens"),
             json.dumps(output, default=str), usage.get("attempts", 1), exec_id),
        )
        self.db.audit(case_id, "stage.completed", {"run_id": run_id, "stage": stage, "duration_ms": int((time.monotonic() - started) * 1000)})

    # ---- stage implementations ---------------------------------------
    def _extraction_check(self, case_id: str) -> dict[str, Any]:
        docs = self.documents.list(case_id)
        issues = []
        for d in docs:
            if d.extraction_status != "extracted":
                issues.append(f"{d.ref_prefix} {d.filename}: extraction {d.extraction_status} ({d.extraction_error or 'no text'})")
            if d.unreadable_pages:
                issues.append(f"{d.ref_prefix} {d.filename}: unreadable pages {d.unreadable_pages}")
        intake = self.cases.get_intake(case_id)
        return {
            "documents": [d.model_dump() for d in docs],
            "issues": issues,
            "intake_missing": intake.missing_essentials() if intake else ["no intake"],
            "ocr_available": __import__("shutil").which("tesseract") is not None,
        }

    def _transcript_path(self, case_id: str, run_id: str, stage: str, attempt: int) -> Path:
        p = self.settings.cases_dir / case_id / "transcripts" / run_id
        p.mkdir(parents=True, exist_ok=True)
        return p / f"{stage}_attempt{attempt}.txt"

    def _run_model_stage(self, case_id: str, run_id: str, stage: str, style: ArgumentStyle, ctx: dict[str, Any], session_id: str,
                         cancel: CancelToken) -> tuple[dict[str, Any], dict[str, Any]]:
        schema = STAGE_SCHEMAS[stage]
        system_prompt, user_prompt = self._build_prompts(case_id, stage, style, ctx["outputs"])
        history: list[dict[str, str]] = []
        attempts = 0
        prompt_tokens = 0
        completion_tokens = 0
        last_error: StructuredOutputError | None = None
        while attempts <= MAX_REPAIR_ATTEMPTS:
            attempts += 1
            req = InferenceRequest(system_prompt=system_prompt, user_prompt=user_prompt, session_id=session_id, stage=stage,
                                   max_tokens=self.settings.max_output_tokens, temperature=self.settings.temperature,
                                   timeout_seconds=self.settings.request_timeout_seconds, history=history)
            resp = self.provider.complete(req, cancel)
            prompt_tokens += resp.prompt_tokens or 0
            completion_tokens += resp.completion_tokens or 0
            self._transcript_path(case_id, run_id, stage, attempts).write_text(resp.text)
            try:
                parsed = parse_model(resp.text, schema)
            except StructuredOutputError as exc:
                last_error = exc
                errors = "\n".join(f"- {e['loc']}: {e['msg']}" for e in exc.errors) or f"- {exc}"
                history = history + [{"role": "assistant", "content": resp.text},
                                     {"role": "user", "content": prompts.REPAIR_INSTRUCTION.format(errors=errors)}]
                self.db.audit(case_id, "stage.repair", {"run_id": run_id, "stage": stage, "attempt": attempts, "errors": exc.errors[:5]})
                continue
            self._enforce_stage_invariants(stage, parsed, style)
            return parsed.model_dump(), {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens, "attempts": attempts,
                                         "model": resp.model, "duration_ms": resp.duration_ms}
        raise PipelineError(f"Stage '{stage}' did not produce valid structured output after {attempts} attempts: {last_error}")

    @staticmethod
    def _enforce_stage_invariants(stage: str, parsed: Any, style: ArgumentStyle) -> None:
        if isinstance(parsed, ArgumentOutput):
            expected = "customer" if stage == "advocate_customer" else "opposing"
            if parsed.position != expected:
                raise StructuredOutputError(f"position must be '{expected}'", [{"loc": "position", "msg": f"expected {expected}"}])
            parsed.style = style

    def _build_prompts(self, case_id: str, stage: str, style: ArgumentStyle, outputs: dict[str, Any]) -> tuple[str, str]:
        case = self.cases.get(case_id)
        intake = self.cases.get_intake(case_id)
        intake_text = prompts.render_intake(intake)
        user_role = intake.user_role if intake else "unknown"
        if stage == "knowledge":
            docs = [d for d in self.documents.list(case_id) if d.extraction_status == "extracted"]
            segs = {d.id: self.documents.segments(case_id, d.id) for d in docs}
            docs_text, truncated = prompts.render_documents(docs, segs, self.settings.max_evidence_chars)
            query_terms = " ".join(filter(None, [intake.narrative[:600] if intake else "", "lease rent default notice lockout deposit repair"]))
            hits = self.authorities.search(query_terms, limit=14)
            auth_text = self.authorities.packet_for_prompt([h["id"] for h in hits], max_chars=24000)
            return (prompts.knowledge_system(prompts.schema_hint(KnowledgeOutput)),
                    prompts.knowledge_user(case.title, case.county, intake_text, docs_text, self.authorities.index_for_prompt(), auth_text, truncated))
        knowledge = outputs.get("knowledge")
        if not knowledge:
            raise PipelineError("Knowledge stage output missing; cannot continue.")
        knowledge_json = json.dumps(knowledge, ensure_ascii=False)
        cited_passages = self._cited_passages(case_id, knowledge)
        auth_ids = [a["authority_id"] for a in knowledge.get("candidate_authorities", []) if a.get("authority_id") not in (None, "", "none")]
        auth_text = self.authorities.packet_for_prompt(auth_ids, max_chars=20000) if auth_ids else "(no library authorities were identified)"
        if stage in ("advocate_customer", "advocate_opposing"):
            position = "customer" if stage == "advocate_customer" else "opposing"
            return (prompts.advocate_system(position, style, user_role, prompts.schema_hint(ArgumentOutput)),
                    prompts.packet_user(intake_text, knowledge_json, cited_passages, auth_text))
        if stage == "judge":
            extra = ("\nCUSTOMER ADVOCATE OUTPUT:\n" + json.dumps(outputs.get("advocate_customer"), ensure_ascii=False) +
                     "\n\nOPPOSING LITIGATOR OUTPUT:\n" + json.dumps(outputs.get("advocate_opposing"), ensure_ascii=False) + "\n")
            return (prompts.judge_system(prompts.schema_hint(JudgeOutput)), prompts.packet_user(intake_text, knowledge_json, cited_passages, auth_text, extra))
        if stage == "senior_partner":
            extra = ("\nCUSTOMER ADVOCATE OUTPUT:\n" + json.dumps(outputs.get("advocate_customer"), ensure_ascii=False) +
                     "\n\nOPPOSING LITIGATOR OUTPUT:\n" + json.dumps(outputs.get("advocate_opposing"), ensure_ascii=False) +
                     "\n\nSKEPTICAL REVIEWER OUTPUT:\n" + json.dumps(outputs.get("judge"), ensure_ascii=False) + "\n")
            return (prompts.senior_partner_system(prompts.schema_hint(SeniorPartnerOutput)), prompts.packet_user(intake_text, knowledge_json, cited_passages, auth_text, extra))
        raise PipelineError(f"No prompt for stage {stage}")

    def _cited_passages(self, case_id: str, knowledge: dict[str, Any]) -> str:
        refs: list[str] = []
        for key in ("key_provisions", "facts", "timeline", "parties"):
            for item in knowledge.get(key, []):
                for r in item.get("refs", []):
                    if r.get("ref") and r["ref"] not in refs and r["ref"].startswith("D"):
                        refs.append(r["ref"])
        blocks = []
        used = 0
        for ref in refs:
            seg = self.documents.resolve_ref(case_id, ref)
            if seg is None:
                blocks.append(f"[{ref}] (reference could not be resolved — do not rely on it)")
                continue
            text = prompts.neutralize(seg.text)
            if used + len(text) > self.settings.max_evidence_chars:
                blocks.append("[... further passages omitted for length ...]")
                break
            used += len(text)
            blocks.append(f"[{ref}]" + (f" ({prompts.neutralize(seg.section_label)})" if seg.section_label else "") + f"\n{text}")
        return "\n\n".join(blocks) if blocks else "(the Knowledge packet cited no document passages)"

    # ---- session retention ----------------------------------------------
    def cleanup_expired_sessions(self) -> int:
        if self._provider is None:
            return 0
        cutoff = (datetime.now(timezone.utc) - timedelta(days=self.settings.session_retention_days)).isoformat(timespec="seconds")
        rows = self.db.query("SELECT id, session_id, case_id FROM stage_executions WHERE session_id IS NOT NULL AND session_cleaned=0 AND started_at < ?", (cutoff,))
        n = 0
        for r in rows:
            if self._provider.cleanup_session(r["session_id"]):
                self.db.execute("UPDATE stage_executions SET session_cleaned=1 WHERE id=?", (r["id"],))
                self.db.audit(r["case_id"], "session.cleaned", {"session_id": r["session_id"]})
                n += 1
        return n
