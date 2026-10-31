"""PDF rendering of the research report with reportlab (reproducible template)."""
from __future__ import annotations

from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas
from reportlab.platypus import KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

NAVY = colors.HexColor("#1f3a5f")
GREY = colors.HexColor("#555555")
LIGHT = colors.HexColor("#f2f4f7")
RED = colors.HexColor("#9b1c1c")
GREEN = colors.HexColor("#1d6b3a")


class NumberedCanvas(canvas.Canvas):
    """Two-pass canvas for 'Page X of Y' with a status banner on every page."""

    def __init__(self, *args, banner: str = "", label: str = "", **kwargs):
        super().__init__(*args, **kwargs)
        self._saved = []
        self._banner = banner
        self._label = label

    def showPage(self):
        self._saved.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        total = len(self._saved)
        for state in self._saved:
            self.__dict__.update(state)
            self._draw_frame(total)
            super().showPage()
        super().save()

    def _draw_frame(self, total: int) -> None:
        w, h = letter
        self.setFont("Helvetica", 8)
        self.setFillColor(GREY)
        self.drawString(inch, h - 0.55 * inch, self._label)
        self.drawRightString(w - inch, h - 0.55 * inch, f"Page {self._pageNumber} of {total}")
        self.setStrokeColor(NAVY)
        self.setLineWidth(0.6)
        self.line(inch, h - 0.62 * inch, w - inch, h - 0.62 * inch)
        self.setFillColor(RED if "DRAFT" in self._banner or "REJECTED" in self._banner else GREEN)
        self.setFont("Helvetica-Bold", 8)
        self.drawCentredString(w / 2, 0.5 * inch, self._banner)


def _styles():
    ss = getSampleStyleSheet()
    return {
        "title": ParagraphStyle("title", parent=ss["Title"], fontSize=22, textColor=NAVY, spaceAfter=10, alignment=TA_CENTER),
        "subtitle": ParagraphStyle("subtitle", parent=ss["Normal"], fontSize=12, textColor=GREY, alignment=TA_CENTER, spaceAfter=6),
        "h1": ParagraphStyle("h1", parent=ss["Heading1"], fontSize=15, textColor=NAVY, spaceBefore=14, spaceAfter=6),
        "h2": ParagraphStyle("h2", parent=ss["Heading2"], fontSize=11.5, textColor=NAVY, spaceBefore=10, spaceAfter=4),
        "body": ParagraphStyle("body", parent=ss["BodyText"], fontSize=9.5, leading=13, spaceAfter=4),
        "small": ParagraphStyle("small", parent=ss["BodyText"], fontSize=8, leading=10.5, textColor=GREY, spaceAfter=2),
        "bullet": ParagraphStyle("bullet", parent=ss["BodyText"], fontSize=9.5, leading=13, leftIndent=12, bulletIndent=2, spaceAfter=2),
        "quote": ParagraphStyle("quote", parent=ss["BodyText"], fontSize=8.5, leading=11.5, leftIndent=14, textColor=GREY, backColor=LIGHT, borderPadding=3, spaceAfter=5),
        "warn": ParagraphStyle("warn", parent=ss["BodyText"], fontSize=9.5, leading=13, textColor=RED, spaceAfter=4),
    }


def P(text: Any, style) -> Paragraph:
    return Paragraph(escape(str(text if text is not None else "")).replace("\n", "<br/>"), style)


def refs_str(refs: list[dict] | None) -> str:
    if not refs:
        return ""
    return " ".join(f"[{r.get('ref')}]" for r in refs if r.get("ref"))


def render_pdf(data: dict[str, Any], out_path: Path) -> Path:
    st = _styles()
    review = data.get("review", {})
    status = review.get("status", "draft")
    banner = {
        "draft": "DRAFT — NOT APPROVED — requires operator review",
        "approved": f"Approved by operator {review.get('reviewer')} on {review.get('reviewed_at')} — not an attorney review",
        "rejected": f"REJECTED by operator {review.get('reviewer')} on {review.get('reviewed_at')}",
    }[status]
    doc = SimpleDocTemplate(str(out_path), pagesize=letter, leftMargin=inch, rightMargin=inch, topMargin=0.9 * inch, bottomMargin=0.85 * inch,
                            title=data["title"], author="Little Guy Legal", subject=data["label"])
    s: list[Any] = []
    case = data["case"]
    # 1. Cover
    s += [Spacer(1, 1.6 * inch), P(data["title"], st["title"]), P(data["label"], st["subtitle"]), Spacer(1, 0.3 * inch),
          P(f"Case: {case['title']}", st["subtitle"]), P(f"Case identifier: {case['id']}", st["small"]),
          P(f"Report {data['report_id']} — version {data['version']} — generated {data['generated_at']}", st["small"]),
          P(f"Jurisdiction: Texas (statewide law) — County: {case['county']} — Matter type: {case['matter_type']}", st["small"]),
          Spacer(1, 0.4 * inch), P(f"Review status: {status.upper()}", st["warn"] if status != "approved" else st["body"])]
    if not data["metadata"].get("provider_is_real_inference", True):
        s.append(P("TEST FIXTURE REPORT: generated with the scripted test provider. Content is canned test data, not model output.", st["warn"]))
    s.append(PageBreak())
    # 2. Scope
    s.append(P("1. Scope and Important Limitations", st["h1"]))
    for item in data["scope_and_limitations"]:
        s.append(Paragraph(escape(item), st["bullet"], bulletText="•"))
    for item in data.get("caveats", []):
        s.append(Paragraph(escape("Analysis caveat: " + item), st["bullet"], bulletText="•"))
    # 3. Executive summary
    s += [P("2. Executive Summary", st["h1"]), P(data["executive_summary"], st["body"])]
    # 4. Background and timeline
    bg = data["background_and_timeline"]
    s.append(P("3. Case Background and Factual Timeline", st["h1"]))
    if bg.get("parties"):
        s.append(P("Parties", st["h2"]))
        for p in bg["parties"]:
            s.append(Paragraph(escape(f"{p['name']} — {p['role']} {refs_str(p.get('refs'))}"), st["bullet"], bulletText="•"))
    s.append(P("Facts (classified by basis)", st["h2"]))
    rows = [["Id", "Statement", "Basis", "Evidence"]]
    for f in bg.get("facts", []):
        rows.append([f["id"], P(f["statement"], st["small"]), f["basis"], P(refs_str(f.get("refs")), st["small"])])
    s.append(_table(rows, [0.45 * inch, 3.9 * inch, 1.1 * inch, 1.05 * inch]))
    if bg.get("timeline"):
        s.append(P("Timeline", st["h2"]))
        rows = [["Date", "Event", "Basis", "Evidence"]]
        for e in bg["timeline"]:
            rows.append([P(e["date"], st["small"]), P(e["description"], st["small"]), e["basis"], P(refs_str(e.get("refs")), st["small"])])
        s.append(_table(rows, [0.95 * inch, 3.6 * inch, 1.0 * inch, 0.95 * inch]))
    # 5. Provisions
    s.append(P("4. Key Lease Provisions", st["h1"]))
    for prov in data["key_lease_provisions"]:
        block = [P(f"{prov['id']}. {prov['title']} {refs_str(prov.get('refs'))}", st["h2"]), P(prov["summary"], st["body"])]
        for r in prov.get("refs", []):
            if r.get("quote"):
                block.append(P(f"“{r['quote']}” — {r['ref']}", st["quote"]))
        if prov.get("ambiguity_notes"):
            block.append(P("Ambiguity: " + prov["ambiguity_notes"], st["small"]))
        s.append(KeepTogether(block))
    # 6. Authorities
    s.append(P("5. Relevant Legal Authorities", st["h1"]))
    if not data["legal_authorities"]:
        s.append(P("No authorities from the local library were identified.", st["body"]))
    for a in data["legal_authorities"]:
        verified = "verified in local library" if a.get("verified_in_library") else "NOT in local library — unverified"
        block = [P(f"{a.get('citation')} ({a.get('binding_status')}; {verified})", st["h2"]), P(a.get("relevance", ""), st["body"])]
        if a.get("quote"):
            block.append(P(f"“{a['quote']}”", st["quote"]))
        if a.get("source_url"):
            block.append(P(f"Source: {a['source_url']} (retrieved {a.get('retrieved_at')})", st["small"]))
        s.append(KeepTogether(block))
    # 7. Issues
    s.append(P("6. Main Legal Issues", st["h1"]))
    for iss in data["main_legal_issues"]:
        s.append(KeepTogether([P(f"{iss['id']}. {iss['title']} {refs_str(iss.get('refs'))}", st["h2"]), P(iss["explanation"], st["body"]),
                               P("Customer position: " + iss["customer_position"], st["body"]), P("Opposing position: " + iss["opposing_position"], st["body"]),
                               P("Current assessment: " + iss["current_assessment"], st["body"])]))
    if data.get("legal_questions"):
        s.append(P("Open legal questions identified", st["h2"]))
        for q in data["legal_questions"]:
            s.append(Paragraph(escape(f"{q['id']}: {q['question']} — {q['why_it_matters']}"), st["bullet"], bulletText="•"))
    # 8/9. Arguments
    for num, key, heading in ((7, "customer_arguments", "Arguments Supporting the Customer's Position"), (8, "opposing_arguments", "Opposing Arguments")):
        s.append(P(f"{num}. {heading}", st["h1"]))
        argout = data.get(key) or {}
        if argout.get("style"):
            s.append(P(f"Argument style: {argout['style'].replace('_', ' ')}", st["small"]))
        for arg in argout.get("arguments", []):
            block = [P(f"{arg['id']}. {arg['title']} — confidence: {arg['confidence']} {refs_str(arg.get('refs'))}", st["h2"]), P(arg["summary"], st["body"])]
            basis = []
            if arg.get("supporting_fact_ids"):
                basis.append("facts " + ", ".join(arg["supporting_fact_ids"]))
            if arg.get("supporting_provision_ids"):
                basis.append("provisions " + ", ".join(arg["supporting_provision_ids"]))
            if arg.get("supporting_authority_ids"):
                basis.append("authorities " + ", ".join(arg["supporting_authority_ids"]))
            if basis:
                block.append(P("Relies on: " + "; ".join(basis), st["small"]))
            for lbl, k in (("Assumptions", "assumptions"), ("Evidentiary weaknesses", "evidentiary_weaknesses"), ("Anticipated counterarguments", "anticipated_counterarguments")):
                if arg.get(k):
                    block.append(P(lbl + ": " + "; ".join(arg[k]), st["small"]))
            block.append(P("Confidence rationale: " + arg["confidence_rationale"], st["small"]))
            s.append(KeepTogether(block))
        if argout.get("overall_assessment"):
            s.append(P("Overall: " + argout["overall_assessment"], st["body"]))
    # 10. Skeptical analysis
    s.append(P("9. Skeptical Analysis and Weaknesses", st["h1"]))
    judge = data.get("skeptical_analysis") or {}
    for ia in judge.get("issue_assessments", []):
        block = [P(f"{ia['issue_id']}. {ia['issue']} — currently stronger: {ia['stronger_side']} {refs_str(ia.get('refs'))}", st["h2"]), P(ia["reasoning"], st["body"])]
        for lbl, k in (("Unsupported claims", "unsupported_claims"), ("Evidence gaps", "evidence_gaps"), ("Procedural concerns", "procedural_concerns")):
            if ia.get(k):
                block.append(P(lbl + ": " + "; ".join(ia[k]), st["small"]))
        s.append(KeepTogether(block))
    if judge.get("unsupported_interpretations"):
        s.append(P("Unsupported interpretations", st["h2"]))
        for u in judge["unsupported_interpretations"]:
            s.append(Paragraph(escape(f"{u['argument_id']}: {u['problem']}"), st["bullet"], bulletText="•"))
    if judge.get("conflicting_provisions"):
        s.append(P("Conflicting provisions", st["h2"]))
        for c in judge["conflicting_provisions"]:
            s.append(Paragraph(escape(f"{', '.join(c['provision_ids'])}: {c['description']}"), st["bullet"], bulletText="•"))
    if judge.get("overall_commentary"):
        s.append(P(judge["overall_commentary"], st["body"]))
    # 11. Missing
    s.append(P("10. Missing Documents and Unresolved Facts", st["h1"]))
    for m in data["missing_information"]:
        s.append(Paragraph(escape(m), st["bullet"], bulletText="•"))
    for n in judge.get("additional_evidence_needed", []):
        s.append(Paragraph(escape(f"[{n['priority']}] {n['item']} — {n['why_it_matters']}"), st["bullet"], bulletText="•"))
    if data.get("unverified_claims"):
        s.append(P("Unverified claims", st["h2"]))
        for u in data["unverified_claims"]:
            s.append(Paragraph(escape(u), st["bullet"], bulletText="•"))
    # 12. Time-sensitive
    s.append(P("11. Time-Sensitive Concerns", st["h1"]))
    if not data["time_sensitive_concerns"]:
        s.append(P("None identified. Deadlines that depend on unknown facts are listed under missing information.", st["body"]))
    for c in data["time_sensitive_concerns"]:
        s.append(Paragraph(escape(f"{c['date_or_deadline']}: {c['concern']} (basis: {c['basis']}) {refs_str(c.get('refs'))}"), st["bullet"], bulletText="•"))
    if data.get("practical_considerations"):
        s.append(P("Practical considerations (informational, not legal advice)", st["h2"]))
        for pc in data["practical_considerations"]:
            s.append(Paragraph(escape(pc), st["bullet"], bulletText="•"))
    if judge.get("attorney_review_required"):
        s.append(P("Conclusions requiring attorney review", st["h2"]))
        for a in judge["attorney_review_required"]:
            s.append(Paragraph(escape(a), st["bullet"], bulletText="•"))
    # 13. Questions
    s.append(P("12. Questions to Ask a Licensed Attorney", st["h1"]))
    for i, q in enumerate(data["questions_for_attorney"], start=1):
        s.append(Paragraph(escape(q), st["bullet"], bulletText=f"{i}."))
    # 14. Evidence appendix
    s.append(PageBreak())
    s.append(P("13. Evidence References and Source Appendix", st["h1"]))
    s.append(P("Documents in this case", st["h2"]))
    rows = [["Ref", "File", "Type", "Pages/segments", "SHA-256"]]
    for d in data["documents"]:
        rows.append([d["ref_prefix"], P(d["filename"], st["small"]), d["doc_kind"], f"{d.get('page_count') or '—'} / {d.get('segment_count') or 0}", P(d["sha256"][:16] + "…", st["small"])])
    s.append(_table(rows, [0.5 * inch, 2.6 * inch, 0.9 * inch, 1.1 * inch, 1.4 * inch]))
    s.append(P("Cited passages", st["h2"]))
    for e in data["evidence_appendix"]:
        head = f"[{e['ref']}] — {e.get('verification_status')}"
        if e.get("document"):
            head += f" — {e['document']}" + (f" ({e['section']})" if e.get("section") else "")
        if e.get("citation"):
            head += f" — {e['citation']}: {e.get('title')}"
        s.append(KeepTogether([P(head, st["body"] if e.get("verification_status") == "verified" else st["warn"]), P(e.get("excerpt", ""), st["quote"])]))
    # 15. Metadata
    s.append(P("14. Research and Verification Metadata", st["h1"]))
    v = data["verification"]
    summ = v.get("summary", {})
    s.append(P(f"Verification checks: {summ.get('total_checks', 0)} total, {summ.get('verified', 0)} verified, {summ.get('failed', 0)} failed "
               f"({summ.get('material_failures', 0)} material). Fabricated authority references rejected: {summ.get('fabricated_authority_refs', 0)}. "
               f"Unsupported findings: {summ.get('unsupported_findings', 0)}.", st["warn"] if v.get("material_failure") else st["body"]))
    for n in v.get("notes", []):
        s.append(Paragraph(escape(n), st["bullet"], bulletText="•"))
    failed = [c for c in v.get("checks", []) if c["status"] != "verified"]
    if failed:
        s.append(P("Unresolved verification findings", st["h2"]))
        rows = [["Finding", "Ref", "Status", "Detail"]]
        for c in failed[:80]:
            rows.append([P(c["target"], st["small"]), P(c.get("ref") or "", st["small"]), P(c["status"], st["small"]), P(c.get("detail", ""), st["small"])])
        s.append(_table(rows, [2.0 * inch, 1.1 * inch, 1.1 * inch, 2.3 * inch]))
    for lim in v.get("limitations", []):
        s.append(P("Limitation: " + lim, st["small"]))
    md = data["metadata"]
    s.append(P(f"Inference provider: {md['provider']} ({'real local inference' if md.get('provider_is_real_inference') else 'SCRIPTED TEST FIXTURE'}); model: {md.get('model')}; "
               f"argument style: {md.get('argument_style')}; run: {md['run_id']}; authority library size: {md.get('authority_library_size')} sections.", st["small"]))
    for stg in md.get("stages", []):
        s.append(P(f"Stage {stg['stage']}: attempts {stg.get('attempt')}, {stg.get('duration_ms')} ms, tokens in/out {stg.get('prompt_tokens')}/{stg.get('completion_tokens')}, session {stg.get('session_id') or '—'}", st["small"]))
    rv = data["review"]
    s.append(P(f"Review: {rv['status']}" + (f" by {rv['reviewer']} at {rv['reviewed_at']}; note: {rv.get('note') or '—'}" if rv.get("reviewed_at") else " (awaiting operator review)"), st["body"]))

    def make_canvas(*args, **kwargs):
        return NumberedCanvas(*args, banner=banner, label=f"{data['label']} — {case['title']}", **kwargs)

    doc.build(s, canvasmaker=make_canvas)
    return out_path


def _table(rows: list[list[Any]], widths: list[float]) -> Table:
    t = Table(rows, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white), ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"), ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#c9ced6")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"), ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT]),
    ]))
    return t
