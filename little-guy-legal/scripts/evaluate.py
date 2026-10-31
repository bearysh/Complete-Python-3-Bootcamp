#!/usr/bin/env python3
"""Reusable evaluation scorecard for a completed analysis run.

Usage:
  python scripts/evaluate.py --case-id <id> [--run-id <id>] [--base http://127.0.0.1:8765]
  python scripts/evaluate.py --results results.json [--expected fixtures/synthetic/expected_findings.json]

Scores extraction/citation accuracy, authority verification, unsupported
conclusion rate, major-issue detection, argument quality proxies, uncertainty
recognition, report readability proxies, and runtime/token usage. The scorecard
is a software-quality instrument; it is NOT a measure of legal correctness.
Attorney-reviewed benchmarks are required before any claim of legal accuracy.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fetch(url: str):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())


def contains_all(text: str, keywords: list[str]) -> bool:
    low = text.lower()
    return all(k.lower() in low for k in keywords)


def flatten(obj) -> str:
    return json.dumps(obj, ensure_ascii=False).lower()


def score(results: dict, expected: dict, run: dict | None = None) -> dict:
    k = results.get("knowledge", {})
    sp = results.get("senior_partner", {})
    judge = results.get("judge", {})
    cust = results.get("advocate_customer", {})
    opp = results.get("advocate_opposing", {})
    ver = results.get("verification", {})
    all_text = flatten(results)
    card: dict = {"sections": {}}

    # 1. Factual extraction accuracy
    facts_text = [(f.get("statement", ""), [r.get("ref") for r in f.get("refs", [])]) for f in k.get("facts", [])]
    hits = 0
    detail = []
    for exp in expected["key_facts"]:
        found = any(contains_all(stmt, exp["keywords"]) and exp["must_cite"] in refs for stmt, refs in facts_text)
        hits += found
        detail.append({"id": exp["id"], "found_with_citation": found})
    card["sections"]["factual_extraction"] = {"score": hits / len(expected["key_facts"]), "detail": detail}

    # 2. Provision identification
    prov_text = [(p.get("title", "") + " " + p.get("summary", "") + " " + " ".join(r.get("quote") or "" for r in p.get("refs", [])), [r.get("ref") for r in p.get("refs", [])]) for p in k.get("key_provisions", [])]
    hits = 0
    detail = []
    for exp in expected["key_provisions"]:
        found = any(contains_all(t, exp["keywords"]) and exp["must_cite"] in refs for t, refs in prov_text)
        hits += found
        detail.append({"id": exp["id"], "found_with_citation": found})
    card["sections"]["provision_identification"] = {"score": hits / len(expected["key_provisions"]), "detail": detail}

    # 3. Citation accuracy (from verifier)
    summ = ver.get("summary", {})
    total = summ.get("total_checks", 0)
    doc_checks = [c for c in ver.get("checks", []) if c["kind"] == "document"]
    doc_ok = sum(1 for c in doc_checks if c["status"] == "verified")
    card["sections"]["document_citation_accuracy"] = {"score": (doc_ok / len(doc_checks)) if doc_checks else 0.0, "verified": doc_ok, "total": len(doc_checks)}

    # 4. Legal authority verification
    cited = [a.get("authority_id") for a in k.get("candidate_authorities", []) if a.get("authority_id") not in (None, "", "none")]
    expected_hit = sum(1 for a in expected["expected_authorities"] if a in cited)
    allowed = set(expected["expected_authorities"]) | set(expected["acceptable_authorities"])
    unexpected = [a for a in cited if a not in allowed]
    card["sections"]["authority_verification"] = {
        "score": expected_hit / len(expected["expected_authorities"]),
        "expected_found": expected_hit, "fabricated_rejected": summ.get("fabricated_authority_refs", 0),
        "cited_outside_expected_set": unexpected, "forbidden_cited": [a for a in cited if a in expected["must_not_cite_authorities"]],
    }

    # 5. Unsupported conclusion rate
    findings = len(k.get("facts", [])) + len(k.get("key_provisions", [])) + len(cust.get("arguments", [])) + len(opp.get("arguments", [])) + len(sp.get("main_issues", []))
    unsupported = summ.get("unsupported_findings", 0) + sum(1 for c in ver.get("checks", []) if c["status"] in ("unknown_authority", "unknown_document", "quote_mismatch") and c["material"])
    card["sections"]["unsupported_conclusion_rate"] = {"rate": (unsupported / findings) if findings else None, "unsupported": unsupported, "findings": findings, "material_failure": ver.get("material_failure")}

    # 6. Major issue detection
    issue_text = flatten(sp.get("main_issues", [])) + flatten(judge.get("issue_assessments", [])) + flatten(k.get("legal_questions", []))
    detail = [{"id": i["id"], "detected": contains_all(issue_text, i["keywords"])} for i in expected["major_issues"]]
    card["sections"]["major_issue_detection"] = {"score": sum(d["detected"] for d in detail) / len(detail), "detail": detail}

    # 7. Quality of competing arguments (proxies)
    def arg_quality(out):
        args = out.get("arguments", [])
        if not args:
            return {"count": 0, "with_weaknesses": 0, "with_counterarguments": 0, "with_evidence": 0}
        return {
            "count": len(args),
            "with_weaknesses": sum(1 for a in args if a.get("evidentiary_weaknesses")) / len(args),
            "with_counterarguments": sum(1 for a in args if a.get("anticipated_counterarguments")) / len(args),
            "with_evidence": sum(1 for a in args if a.get("refs") or a.get("supporting_fact_ids") or a.get("supporting_provision_ids")) / len(args),
        }
    c_titles = {a["title"] for a in cust.get("arguments", [])}
    o_titles = {a["title"] for a in opp.get("arguments", [])}
    card["sections"]["argument_quality"] = {"customer": arg_quality(cust), "opposing": arg_quality(opp), "materially_different": bool(c_titles and o_titles and not (c_titles & o_titles)),
                                            "judge_unsupported_interpretations": len(judge.get("unsupported_interpretations", []))}

    # 8. Uncertainty recognition
    miss_text = flatten(k.get("missing_information", [])) + flatten(sp.get("information_gaps", [])) + flatten(judge.get("additional_evidence_needed", []))
    detail = [{"id": m["id"], "identified": contains_all(miss_text, m["keywords"])} for m in expected["expected_missing_evidence"]]
    card["sections"]["uncertainty_recognition"] = {
        "missing_evidence_score": sum(d["identified"] for d in detail) / len(detail), "detail": detail,
        "ambiguity_recognized": bool(judge.get("conflicting_provisions")) or any(p.get("ambiguity_notes") for p in k.get("key_provisions", [])),
        "timing_issue_recognized": contains_all(flatten(sp.get("time_sensitive_concerns", [])), expected["expected_timing_issue"]["keywords"]),
        "unverified_claims_listed": len(sp.get("unverified_claims", [])),
        "forbidden_certainty_phrases": [p for p in expected["forbidden_phrases"] if p.lower() in all_text],
        "basis_distribution": _basis_distribution(k.get("facts", [])),
    }

    # 9. Report readability proxies
    summary = sp.get("executive_summary", "")
    sentences = [s for s in re.split(r"[.!?]+", summary) if s.strip()]
    words = summary.split()
    card["sections"]["report_readability"] = {
        "executive_summary_words": len(words), "avg_sentence_words": (len(words) / len(sentences)) if sentences else None,
        "questions_for_attorney": len(sp.get("questions_for_attorney", [])), "main_issues": len(sp.get("main_issues", [])),
    }

    # 10. Runtime and tokens
    if run:
        stages = run.get("stages", [])
        card["sections"]["runtime"] = {
            "total_ms": sum(s.get("duration_ms") or 0 for s in stages),
            "per_stage_ms": {s["stage"]: s.get("duration_ms") for s in stages},
            "prompt_tokens": sum(s.get("prompt_tokens") or 0 for s in stages),
            "completion_tokens": sum(s.get("completion_tokens") or 0 for s in stages),
            "provider": run.get("provider"), "model": run.get("model"),
        }
    card["disclaimer"] = "Software-quality scorecard only. Does not establish legal accuracy; attorney review is required for that."
    return card


def _basis_distribution(facts):
    out: dict[str, int] = {}
    for f in facts:
        out[f.get("basis", "?")] = out.get(f.get("basis", "?"), 0) + 1
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8765")
    ap.add_argument("--case-id")
    ap.add_argument("--run-id")
    ap.add_argument("--results", help="path to a saved results JSON (stage outputs)")
    ap.add_argument("--expected", default=str(ROOT / "fixtures/synthetic/expected_findings.json"))
    ap.add_argument("--out", help="write scorecard JSON here")
    a = ap.parse_args()
    expected = json.loads(Path(a.expected).read_text())
    run = None
    if a.results:
        results = json.loads(Path(a.results).read_text())
    else:
        if not a.case_id:
            ap.error("--case-id or --results required")
        run_id = a.run_id or fetch(f"{a.base}/api/cases/{a.case_id}/analysis")["id"]
        run = fetch(f"{a.base}/api/cases/{a.case_id}/analysis/runs/{run_id}")
        results = fetch(f"{a.base}/api/cases/{a.case_id}/analysis/runs/{run_id}/results")
    card = score(results, expected, run)
    text = json.dumps(card, indent=1, ensure_ascii=False)
    if a.out:
        Path(a.out).write_text(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
