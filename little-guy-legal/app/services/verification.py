"""Stage F — Independent verification, implemented in application code (no model involved).

Resolves every evidence reference in the stage outputs to actual stored text,
checks quotes, rejects authority ids that are not in the local library, and flags
findings that carry no evidence. Material failures block automatic approval.
"""
from __future__ import annotations

import re
from typing import Any

from ..models.common import AUTH_REF_RE, DOC_REF_RE, EvidenceRef
from ..models.stages import ArgumentOutput, JudgeOutput, KnowledgeOutput, SeniorPartnerOutput
from ..models.verification import VerificationCheck, VerificationReport, VerificationSummary
from .authority import AuthorityService
from .documents import DocumentService

NUM_TOKEN_RE = re.compile(r"\$\s?\d[\d,]*(?:\.\d{2})?|\b(?:19|20)\d{2}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}/\d{4}\b|\b(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}, \d{4}\b")


_MONTHS = {m: i for i, m in enumerate(["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"], start=1)}


def _canon_date(tok: str) -> str | None:
    t = tok.strip()
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", t)
    if m:
        return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", t)
    if m:
        return f"{m.group(3)}-{int(m.group(1)):02d}-{int(m.group(2)):02d}"
    m = re.match(r"^([A-Za-z]+) (\d{1,2}), (\d{4})$", t)
    if m and m.group(1).lower() in _MONTHS:
        return f"{m.group(3)}-{_MONTHS[m.group(1).lower()]:02d}-{int(m.group(2)):02d}"
    return None


def _canon_amount(tok: str) -> float | None:
    t = tok.strip()
    if not t.startswith("$"):
        return None
    try:
        return round(float(t[1:].replace(",", "").strip()), 2)
    except ValueError:
        return None


def _norm(text: str) -> str:
    text = text.replace("‹", "<").replace("›", ">").replace("“", '"').replace("”", '"').replace("’", "'").replace("—", "-").replace("–", "-")
    return re.sub(r"\s+", " ", text).strip().lower()


def quote_matches(quote: str, source: str) -> tuple[bool, str]:
    q = _norm(quote).strip('"\' ')
    s = _norm(source)
    if not q:
        return True, "no_quote"
    if q in s:
        return True, "exact"
    words = q.split()
    if len(words) < 5:
        return False, "short quote not found verbatim"
    n = 5
    grams = [" ".join(words[i : i + n]) for i in range(len(words) - n + 1)]
    hits = sum(1 for g in grams if g in s)
    ratio = hits / len(grams)
    if ratio >= 0.8:
        return True, f"fuzzy ({ratio:.0%} of 5-word spans found)"
    return False, f"quote not found in passage ({ratio:.0%} of 5-word spans found)"


class VerificationService:
    def __init__(self, documents: DocumentService, authorities: AuthorityService):
        self.documents = documents
        self.authorities = authorities

    def verify(self, run_id: str, case_id: str, outputs: dict[str, Any]) -> VerificationReport:
        checks: list[VerificationCheck] = []
        knowledge = KnowledgeOutput.model_validate(outputs["knowledge"]) if outputs.get("knowledge") else None
        customer = ArgumentOutput.model_validate(outputs["advocate_customer"]) if outputs.get("advocate_customer") else None
        opposing = ArgumentOutput.model_validate(outputs["advocate_opposing"]) if outputs.get("advocate_opposing") else None
        judge = JudgeOutput.model_validate(outputs["judge"]) if outputs.get("judge") else None
        partner = SeniorPartnerOutput.model_validate(outputs["senior_partner"]) if outputs.get("senior_partner") else None

        known_fact_ids: set[str] = set()
        known_prov_ids: set[str] = set()
        known_auth_ids: set[str] = set()

        if knowledge:
            for p in knowledge.parties:
                self._check_refs(case_id, f"knowledge.parties.{p.name}", p.refs, checks, material=False, statement=None)
            for prov in knowledge.key_provisions:
                known_prov_ids.add(prov.id)
                if not prov.refs:
                    checks.append(VerificationCheck(target=f"knowledge.key_provisions.{prov.id}", ref=None, kind="finding", status="no_evidence", material=True,
                                                    detail="Key provision has no document reference."))
                self._check_refs(case_id, f"knowledge.key_provisions.{prov.id}", prov.refs, checks, material=True, statement=None)
            for fact in knowledge.facts:
                known_fact_ids.add(fact.id)
                if fact.basis == "documented" and not fact.refs:
                    checks.append(VerificationCheck(target=f"knowledge.facts.{fact.id}", ref=None, kind="finding", status="no_evidence", material=True,
                                                    detail="Fact marked 'documented' has no document reference."))
                self._check_refs(case_id, f"knowledge.facts.{fact.id}", fact.refs, checks, material=fact.basis == "documented", statement=fact.statement)
            for i, ev in enumerate(knowledge.timeline, start=1):
                if ev.basis == "documented" and not ev.refs:
                    checks.append(VerificationCheck(target=f"knowledge.timeline.{i}", ref=None, kind="finding", status="no_evidence", material=False,
                                                    detail="Timeline event marked 'documented' has no reference."))
                self._check_refs(case_id, f"knowledge.timeline.{i}", ev.refs, checks, material=False, statement=ev.description)
            for i, a in enumerate(knowledge.candidate_authorities, start=1):
                known_auth_ids.add(a.authority_id)
                self._check_authority(f"knowledge.candidate_authorities.{i}", a.authority_id, a.quote, a.citation, checks, allow_none=True)

        for label, arg_out in (("advocate_customer", customer), ("advocate_opposing", opposing)):
            if not arg_out:
                continue
            for arg in arg_out.arguments:
                target = f"{label}.arguments.{arg.id}"
                if not arg.refs and not arg.supporting_fact_ids and not arg.supporting_provision_ids and not arg.supporting_authority_ids:
                    checks.append(VerificationCheck(target=target, ref=None, kind="finding", status="no_evidence", material=True,
                                                    detail="Argument cites no facts, provisions, authorities or passages."))
                for fid in arg.supporting_fact_ids:
                    if knowledge and fid not in known_fact_ids:
                        checks.append(VerificationCheck(target=target, ref=fid, kind="finding", status="invalid_ref", material=True,
                                                        detail=f"Fact id {fid} does not exist in the Knowledge packet."))
                for pid in arg.supporting_provision_ids:
                    if knowledge and pid not in known_prov_ids:
                        checks.append(VerificationCheck(target=target, ref=pid, kind="finding", status="invalid_ref", material=True,
                                                        detail=f"Provision id {pid} does not exist in the Knowledge packet."))
                for aid in arg.supporting_authority_ids:
                    self._check_authority(target, aid, None, None, checks, allow_none=True)
                self._check_refs(case_id, target, arg.refs, checks, material=True, statement=None)

        if judge:
            for ia in judge.issue_assessments:
                self._check_refs(case_id, f"judge.issue_assessments.{ia.issue_id}", ia.refs, checks, material=False, statement=None)

        if partner:
            for issue in partner.main_issues:
                if not issue.refs:
                    checks.append(VerificationCheck(target=f"senior_partner.main_issues.{issue.id}", ref=None, kind="finding", status="no_evidence", material=False,
                                                    detail="Issue summary carries no evidence reference; treat as analytical synthesis."))
                self._check_refs(case_id, f"senior_partner.main_issues.{issue.id}", issue.refs, checks, material=True, statement=None)
            for i, c in enumerate(partner.time_sensitive_concerns, start=1):
                if c.basis == "documented" and not c.refs:
                    checks.append(VerificationCheck(target=f"senior_partner.time_sensitive_concerns.{i}", ref=None, kind="finding", status="no_evidence", material=True,
                                                    detail="Time-sensitive concern marked documented without a reference."))
                self._check_refs(case_id, f"senior_partner.time_sensitive_concerns.{i}", c.refs, checks, material=True, statement=c.date_or_deadline)

        failed = [c for c in checks if c.status != "verified"]
        material = [c for c in failed if c.material]
        summary = VerificationSummary(
            total_checks=len(checks),
            verified=len(checks) - len(failed),
            failed=len(failed),
            material_failures=len(material),
            unsupported_findings=sum(1 for c in failed if c.status == "no_evidence" and c.kind == "finding"),
            fabricated_authority_refs=sum(1 for c in failed if c.status == "unknown_authority"),
        )
        notes = []
        if summary.fabricated_authority_refs:
            notes.append(f"{summary.fabricated_authority_refs} authority reference(s) do not exist in the local library and were rejected.")
        if summary.unsupported_findings:
            notes.append(f"{summary.unsupported_findings} finding(s) carry no supporting evidence.")
        if not checks:
            notes.append("No evidence references were produced; nothing could be verified.")
        return VerificationReport(
            run_id=run_id,
            checks=checks,
            summary=summary,
            material_failure=bool(material) or not checks,
            notes=notes,
            limitations=[
                "Verification confirms that citations resolve to stored text and that quotes match. It does not confirm that a statute is current, remains good law, or applies to these facts.",
                "The authority library contains Texas statutes only; rules of procedure, case law, and local rules are absent, so references to them are reported as unverified.",
                "Contradiction detection is limited to numeric/date consistency between a fact and its cited passage plus the skeptical reviewer's findings.",
            ],
        )

    # ------------------------------------------------------------------
    def _check_refs(self, case_id: str, target: str, refs: list[EvidenceRef], checks: list[VerificationCheck], material: bool,
                    statement: str | None) -> None:
        resolved = []
        for ref in refs:
            kind = ref.kind
            if kind == "document":
                seg = self.documents.resolve_ref(case_id, ref.ref)
                if seg is None:
                    m = DOC_REF_RE.match(ref.ref)
                    doc_exists = any(d.ref_prefix == f"D{m.group('doc')}" for d in self.documents.list(case_id)) if m else False
                    checks.append(VerificationCheck(target=target, ref=ref.ref, kind="document",
                                                    status="location_not_found" if doc_exists else "unknown_document", material=material,
                                                    detail="Referenced page/paragraph does not exist in this case." if doc_exists else "Referenced document does not exist in this case."))
                    continue
                ok, why = quote_matches(ref.quote or "", seg.text)
                loc = f"{seg.ref}" + (f" ({seg.section_label})" if seg.section_label else "")
                if not ok:
                    checks.append(VerificationCheck(target=target, ref=ref.ref, kind="document", status="quote_mismatch", material=material,
                                                    detail=why, resolved_location=loc))
                    continue
                resolved.append(seg)
                checks.append(VerificationCheck(target=target, ref=ref.ref, kind="document", status="verified", material=material, detail=why, resolved_location=loc))
            elif kind == "authority":
                aid = AUTH_REF_RE.match(ref.ref).group("id")
                self._check_authority(target, aid, ref.quote, None, checks, allow_none=False, ref_label=ref.ref)
            else:
                checks.append(VerificationCheck(target=target, ref=ref.ref, kind="finding", status="invalid_ref", material=material,
                                                detail="Reference label is not in a recognized format."))

        if statement and resolved:
            self._consistency_check(case_id, target, statement, resolved, checks)

    def _consistency_check(self, case_id: str, target: str, statement: str, segments: list, checks: list[VerificationCheck]) -> None:
        """Amounts and dates asserted in a finding should appear in the cited passages (or, for DOCX, in nearby paragraphs such as email headers)."""
        corpus_parts = []
        for seg in segments:
            corpus_parts.append(seg.text)
            if seg.locator_type == "paragraph" and seg.paragraph_index is not None:
                for n in range(seg.paragraph_index - 6, seg.paragraph_index + 2):
                    if n == seg.paragraph_index or n < 1:
                        continue
                    neighbor = self.documents.resolve_ref(case_id, f"{seg.ref.split(':')[0]}:para{n}")
                    if neighbor is not None:
                        corpus_parts.append(neighbor.text)
        corpus_dates = {d for d in (_canon_date(t) for t in NUM_TOKEN_RE.findall(" ".join(corpus_parts))) if d}
        corpus_amounts = {a for a in (_canon_amount(t) for t in NUM_TOKEN_RE.findall(" ".join(corpus_parts))) if a is not None}
        missing = []
        for tok in NUM_TOKEN_RE.findall(statement):
            d, a = _canon_date(tok), _canon_amount(tok)
            if d and d not in corpus_dates:
                missing.append(tok)
            elif a is not None and a not in corpus_amounts:
                missing.append(tok)
        if missing:
            checks.append(VerificationCheck(target=target, ref=None, kind="finding", status="consistency_warning", material=False,
                                            detail=f"Amounts/dates in the finding were not found in the cited passages: {', '.join(missing[:4])}"))

    def _check_authority(self, target: str, authority_id: str, quote: str | None, citation: str | None, checks: list[VerificationCheck],
                         allow_none: bool, ref_label: str | None = None) -> None:
        label = ref_label or f"A:{authority_id}"
        if authority_id in ("", "none", None):
            if allow_none:
                checks.append(VerificationCheck(target=target, ref=label, kind="authority", status="no_evidence", material=False,
                                                detail="Authority not in local library; treat the legal proposition as unverified."))
            return
        auth = self.authorities.get(authority_id)
        if auth is None:
            checks.append(VerificationCheck(target=target, ref=label, kind="authority", status="unknown_authority", material=True,
                                            detail="Authority id does not exist in the local library (possible fabrication)."))
            return
        ok, why = self.authorities.verify_quote(authority_id, quote or "")
        detail = why
        if citation and auth["citation"].split("§")[-1].strip() not in citation:
            detail += f"; citation text '{citation[:60]}' does not name section {auth['citation']}"
        checks.append(VerificationCheck(target=target, ref=label, kind="authority", status="verified" if ok else "quote_mismatch", material=True,
                                        detail=detail, resolved_location=auth["citation"]))
