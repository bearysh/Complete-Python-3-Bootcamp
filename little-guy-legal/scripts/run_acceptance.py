#!/usr/bin/env python3
"""End-to-end acceptance run against a live Little Guy Legal server.

Creates the synthetic case, uploads the fixture documents, submits intake,
runs the analysis, waits for completion, evaluates the result, approves the
report as operator, and copies the PDF/JSON into --out. Exits non-zero if any
acceptance criterion the software can check fails.

Usage: python scripts/run_acceptance.py [--base http://127.0.0.1:8765] [--style by_the_book] [--out docs/acceptance] [--reviewer NAME]
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import shutil
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures/synthetic/files"
sys.path.insert(0, str(ROOT / "scripts"))
from evaluate import score  # noqa: E402

INTAKE = {
    "user_role": "tenant",
    "narrative": "Our rooftop HVAC compressor failed in June 2025. The landlord said it was our responsibility; we replaced it for $8,400 and applied the cost against August rent. The landlord sent a notice of default by email on August 11 (they say also by certified mail, which we never received) and changed our locks on August 26, demanding the rent plus a $1,500 lockout fee for a new key.",
    "desired_outcome": "Regain possession of the premises quickly and recover the $8,400 repair cost, or at least understand our exposure before meeting an attorney.",
    "key_dates": [{"label": "HVAC failure reported", "date": "2025-06-10", "confirmed": True}, {"label": "Notice of default", "date": "2025-08-11", "confirmed": True}, {"label": "Lockout", "date": "2025-08-26", "confirmed": True}],
    "prior_notices": [{"kind": "notice of default", "date": "2025-08-11", "description": "Landlord letter demanding $7,717.50 within ten days"}],
}


def req(method: str, url: str, data=None, headers=None, raw=None):
    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    h = {"Content-Type": "application/json"} if data is not None else {}
    h.update(headers or {})
    r = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            ct = resp.headers.get("Content-Type", "")
            payload = resp.read()
            return resp.status, (json.loads(payload) if "json" in ct else payload)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def upload(base: str, cid: str, path: Path):
    boundary = uuid.uuid4().hex
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{path.name}\"\r\nContent-Type: {mime}\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    return req("POST", f"{base}/api/cases/{cid}/documents", raw=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8765")
    ap.add_argument("--style", default="by_the_book")
    ap.add_argument("--out", default=str(ROOT / "docs/acceptance"))
    ap.add_argument("--reviewer", default="Acceptance Operator")
    ap.add_argument("--timeout", type=float, default=7200)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    checks: list[tuple[str, bool, str]] = []

    def check(name, ok, detail=""):
        checks.append((name, bool(ok), detail))
        print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail else ""))

    st, health = req("GET", f"{a.base}/api/health")
    check("1. application reachable on localhost", st == 200, a.base)
    prov = health.get("provider", {})
    check("4. real local inference provider configured", prov.get("configured") and prov.get("is_real_inference"),
          f"provider={prov.get('provider')} model={prov.get('model')}" + ("" if prov.get("is_real_inference") else " (SCRIPTED TEST PROVIDER — criterion NOT met)"))
    st, case = req("POST", f"{a.base}/api/cases", {"title": "Brazos Bend Coffee Roasters v. Ridgmar Crossing Partners (synthetic acceptance)"})
    cid = case["id"]
    docs = []
    for name in ("01_commercial_lease.pdf", "02_notice_of_default.docx", "03_email_chain.docx"):
        st, d = upload(a.base, cid, FIXTURES / name)
        docs.append(d)
    check("2. PDF and DOCX uploaded and extracted", all(d.get("extraction_status") == "extracted" for d in docs), ", ".join(f"{d.get('ref_prefix')}={d.get('segment_count')} segments" for d in docs))
    req("PUT", f"{a.base}/api/cases/{cid}/intake", INTAKE)
    st, run = req("POST", f"{a.base}/api/cases/{cid}/analysis", {"argument_style": a.style})
    if st != 202:
        check("3. analysis started", False, str(run))
        return _finish(checks, out)
    run_id = run["id"]
    started = time.time()
    while time.time() - started < a.timeout:
        st, run = req("GET", f"{a.base}/api/cases/{cid}/analysis/runs/{run_id}")
        cur = run.get("current_stage")
        print(f"   … {run['status']} stage={cur} elapsed={int(time.time() - started)}s", end="\r")
        if run["status"] in ("completed", "failed", "cancelled", "interrupted"):
            break
        time.sleep(3)
    print()
    check("3. all specialist stages executed", run["status"] == "completed" and all(s["status"] == "completed" for s in run["stages"]), run.get("error") or f"{int(time.time() - started)}s")
    if run["status"] != "completed":
        return _finish(checks, out)
    st, results = req("GET", f"{a.base}/api/cases/{cid}/analysis/runs/{run_id}/results")
    (out / "results.json").write_text(json.dumps(results, indent=1, ensure_ascii=False))
    (out / "run.json").write_text(json.dumps(run, indent=1))
    ver = results["verification"]
    check("7. verification flagged/unverified items reported", "summary" in ver, json.dumps(ver["summary"]))
    sample_ref = next((r["ref"] for f in results["knowledge"]["facts"] for r in f.get("refs", []) if r["ref"].startswith("D")), None)
    st, seg = req("GET", f"{a.base}/api/cases/{cid}/segments/{sample_ref}") if sample_ref else (404, {})
    check("6. evidence references inspectable", st == 200, f"{sample_ref} -> {seg.get('section_label') if st == 200 else 'not resolved'}")
    st, reports = req("GET", f"{a.base}/api/cases/{cid}/reports")
    rep = reports[0]
    check("8a. draft report awaiting human approval", rep["status"] == "draft")
    st, review = req("POST", f"{a.base}/api/cases/{cid}/reports/{rep['id']}/review", {"action": "approve", "reviewer": a.reviewer, "note": "Acceptance run", "acknowledge_verification_failures": bool(ver.get("material_failure"))})
    check("8b. operator approval recorded", st == 200 and review.get("status") == "approved", f"reviewed_at={review.get('reviewed_at')} acknowledged_failures={review.get('acknowledged_failures')}")
    st, pdf = req("GET", f"{a.base}/api/cases/{cid}/reports/{rep['id']}/pdf")
    ok_pdf = st == 200 and isinstance(pdf, (bytes, bytearray)) and pdf.startswith(b"%PDF") and len(pdf) > 20000
    check("9. readable PDF exported", ok_pdf, f"{len(pdf) if isinstance(pdf, (bytes, bytearray)) else 0} bytes")
    if ok_pdf:
        (out / "Little-Guy-Legal-Case-Research-Report.pdf").write_bytes(pdf)
    st, rj = req("GET", f"{a.base}/api/cases/{cid}/reports/{rep['id']}/json")
    if st == 200:
        (out / "Little-Guy-Legal-Case-Research-Report.json").write_bytes(rj if isinstance(rj, bytes) else json.dumps(rj).encode())
    card = score(results, json.loads((ROOT / "fixtures/synthetic/expected_findings.json").read_text()), run)
    (out / "scorecard.json").write_text(json.dumps(card, indent=1, ensure_ascii=False))
    secs = card["sections"]
    check("eval: major issues detected", secs["major_issue_detection"]["score"] >= 0.8, f"{secs['major_issue_detection']['score']:.0%}")
    check("eval: competing arguments materially different", secs["argument_quality"]["materially_different"])
    check("eval: no forbidden certainty phrases", not secs["uncertainty_recognition"]["forbidden_certainty_phrases"])
    check("eval: no fabricated authorities accepted", not secs["authority_verification"]["forbidden_cited"])
    (out / "case_id.txt").write_text(cid)
    return _finish(checks, out)


def _finish(checks, out: Path) -> int:
    (out / "acceptance_checks.json").write_text(json.dumps([{"check": n, "pass": ok, "detail": d} for n, ok, d in checks], indent=1))
    failed = [n for n, ok, _ in checks if not ok]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} acceptance checks passed. Artifacts in {out}")
    if failed:
        print("Failed: " + "; ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
