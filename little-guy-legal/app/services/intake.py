"""Deterministic (non-AI) intake helpers: infer high-impact facts from documents for user confirmation."""
from __future__ import annotations

import re

from .documents import DocumentService

DATE_RE = re.compile(
    r"\b(?:(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}"
    r"|\d{1,2}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2})\b"
)
MONEY_RE = re.compile(r"\$\s?\d{1,3}(?:,\d{3})*(?:\.\d{2})?")
PARTY_RE = re.compile(
    r"(?P<name>[A-Z][A-Za-z0-9&\.,' \-]{2,80}?(?:LLC|L\.L\.C\.|LP|L\.P\.|Inc\.|Corporation|Corp\.|Ltd\.|Company))\s*"
    r"[\(\[\"“]+\s*(?:the\s+)?[\"“]?(?P<role>Landlord|Tenant|Lessor|Lessee|Guarantor)",
    re.I,
)


def suggest_intake(documents: DocumentService, case_id: str) -> dict:
    """Return suggested parties, dates, amounts and notice indicators with their source refs."""
    parties: dict[str, dict] = {}
    dates: list[dict] = []
    amounts: list[dict] = []
    notices: list[dict] = []
    seen_dates: set[str] = set()
    for doc in documents.list(case_id):
        if doc.extraction_status != "extracted":
            continue
        for seg in documents.segments(case_id, doc.id):
            for m in PARTY_RE.finditer(seg.text):
                role = m.group("role").lower().replace("lessor", "landlord").replace("lessee", "tenant")
                name = re.sub(r"\s+", " ", m.group("name")).strip(" ,")
                # drop lead-in words such as "is entered into between" / "and"
                name = re.sub(r"^(?:[a-z][A-Za-z]*\s+)+", "", name).strip()
                parties.setdefault(role, {"name": name, "ref": seg.ref})
            if doc.doc_kind in {"notice", "communication"} or len(dates) < 40:
                for m in DATE_RE.finditer(seg.text):
                    d = m.group(0)
                    if d in seen_dates:
                        continue
                    seen_dates.add(d)
                    context = seg.text[max(0, m.start() - 70): m.end() + 70].replace("\n", " ")
                    dates.append({"date": d, "context": context, "ref": seg.ref, "document": doc.filename})
            if doc.doc_kind == "lease" and len(amounts) < 15:
                for m in MONEY_RE.finditer(seg.text):
                    context = seg.text[max(0, m.start() - 60): m.end() + 40].replace("\n", " ")
                    amounts.append({"amount": m.group(0), "context": context, "ref": seg.ref})
            low = seg.text.lower()
            for kw in ("notice of default", "notice to vacate", "demand for payment", "petition", "lawsuit", "writ of", "lockout", "locked out", "changed the locks", "locks changed", "terminat"):
                if re.search(r"\b" + re.escape(kw), low):
                    notices.append({"indicator": kw, "ref": seg.ref, "document": doc.filename})
                    break
    return {
        "parties": parties,
        "dates": dates[:40],
        "amounts": amounts,
        "notice_indicators": notices[:20],
        "note": "Suggestions are extracted by pattern matching, not AI. Confirm anything that matters before analysis.",
    }
