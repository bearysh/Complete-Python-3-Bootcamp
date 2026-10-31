import json
import time
from pathlib import Path

from tests.conftest import INTAKE, create_case_with_docs, make_settings, run_analysis, upload_fixture_docs


def test_intake_flow_and_document_isolation(client):
    a = create_case_with_docs(client, "Case A")
    b = client.post("/api/cases", json={"title": "Case B"}).json()["id"]
    upload_fixture_docs(client, b, names=("02_notice_of_default.docx",))
    # refs resolve only within their own case
    assert client.get(f"/api/cases/{a}/segments/D1:p4").status_code == 200
    assert client.get(f"/api/cases/{b}/segments/D1:p4").status_code == 404  # B's D1 is a DOCX with paragraphs
    assert client.get(f"/api/cases/{b}/segments/D3:para42").status_code == 404
    # search is case-scoped
    assert client.get(f"/api/cases/{b}/search?q=rooftop compressor").json() == []
    assert client.get(f"/api/cases/{a}/search?q=rooftop compressor").json()
    # documents of A cannot be fetched via B
    doc_a = client.get(f"/api/cases/{a}/documents").json()[0]["id"]
    assert client.get(f"/api/cases/{b}/documents/{doc_a}/segments").status_code == 404
    assert client.get(f"/api/cases/{b}/documents/{doc_a}/original").status_code == 404


def test_full_workflow_persists_and_approves(client, settings):
    cid = create_case_with_docs(client)
    assert client.get(f"/api/cases/{cid}").json()["status"] == "intake"
    run = run_analysis(client, cid)
    assert run["status"] == "completed"
    assert [s["status"] for s in run["stages"]] == ["completed"] * 8
    assert all(s["session_id"] for s in run["stages"] if s["stage"] in ("knowledge", "judge"))
    sessions = {s["session_id"] for s in run["stages"] if s["session_id"]}
    assert len(sessions) == 5  # one unpredictable session per model stage
    results = client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}/results").json()
    assert results["advocate_customer"]["position"] == "customer" and results["advocate_opposing"]["position"] == "opposing"
    # arguments for the two sides are materially different
    c_titles = {a["title"] for a in results["advocate_customer"]["arguments"]}
    o_titles = {a["title"] for a in results["advocate_opposing"]["arguments"]}
    assert not (c_titles & o_titles)
    assert results["judge"]["additional_evidence_needed"]
    reports = client.get(f"/api/cases/{cid}/reports").json()
    assert len(reports) == 1 and reports[0]["status"] == "draft"
    rid = reports[0]["id"]
    pdf = client.get(f"/api/cases/{cid}/reports/{rid}/pdf")
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF") and len(pdf.content) > 20000
    data = client.get(f"/api/cases/{cid}/reports/{rid}").json()["data"]
    assert data["label"] == "AI-Assisted Legal Research — For Attorney Review"
    assert data["review"]["status"] == "draft"
    assert data["metadata"]["provider_is_real_inference"] is False
    # reviewer name required; reject path
    assert client.post(f"/api/cases/{cid}/reports/{rid}/review", json={"action": "approve", "reviewer": ""}).status_code == 422
    r = client.post(f"/api/cases/{cid}/reports/{rid}/review", json={"action": "approve", "reviewer": "Operator One", "note": "Reviewed."})
    assert r.status_code == 200 and r.json()["status"] == "approved" and r.json()["reviewed_at"]
    assert client.post(f"/api/cases/{cid}/reports/{rid}/review", json={"action": "reject", "reviewer": "X"}).status_code == 400
    approved_pdf = client.get(f"/api/cases/{cid}/reports/{rid}/pdf").content
    assert approved_pdf.startswith(b"%PDF")
    assert client.get(f"/api/cases/{cid}").json()["status"] == "report_approved"
    # audit trail recorded the approval
    events = [e["event"] for e in client.get(f"/api/cases/{cid}/audit").json()]
    assert "report.approved" in events and "run.completed" in events
    # storage layout: originals immutable, outside the repo
    originals = list((settings.cases_dir / cid / "originals").iterdir())
    assert len(originals) == 3 and all(not (p.stat().st_mode & 0o222) for p in originals)


def test_restart_recovers_state_and_resume_skips_completed_stages(tmp_path):
    from fastapi.testclient import TestClient

    from app.main import create_app

    settings = make_settings(tmp_path)
    app = create_app(settings)
    with TestClient(app) as client:
        cid = create_case_with_docs(client)
        run = run_analysis(client, cid)
        assert run["status"] == "completed"
        rid = client.get(f"/api/cases/{cid}/reports").json()[0]["id"]
        # simulate an interrupted run: mark running in DB directly
        state = app.state.lgl
        state.db.execute("UPDATE analysis_runs SET status='running' WHERE id=?", (run["id"],))
        state.db.execute("DELETE FROM stage_executions WHERE run_id=? AND stage IN ('senior_partner','verification','report_draft')", (run["id"],))
    # restart the application against the same data dir
    app2 = create_app(settings)
    with TestClient(app2) as client:
        case = client.get(f"/api/cases/{cid}").json()
        assert case["document_count"] == 3 and case["has_intake"]
        run2 = client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}").json()
        assert run2["status"] == "interrupted"
        done_before = {s["stage"]: s["started_at"] for s in run2["stages"] if s["status"] == "completed"}
        assert "knowledge" in done_before and "senior_partner" not in done_before
        r = client.post(f"/api/cases/{cid}/analysis/runs/{run['id']}/resume")
        assert r.status_code == 202
        for _ in range(300):
            run3 = client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}").json()
            if run3["status"] in ("completed", "failed"):
                break
            time.sleep(0.1)
        assert run3["status"] == "completed", run3
        after = {s["stage"]: s["started_at"] for s in run3["stages"]}
        assert after["knowledge"] == done_before["knowledge"]  # not re-executed
        assert client.get(f"/api/cases/{cid}/reports/{rid}/pdf").status_code == 200  # earlier report survived
        assert len(client.get(f"/api/cases/{cid}/reports").json()) == 2


def test_cancel_and_failed_start_conditions(client):
    cid = client.post("/api/cases", json={"title": "No docs"}).json()["id"]
    r = client.post(f"/api/cases/{cid}/analysis", json={"argument_style": "by_the_book"})
    assert r.status_code == 409 and "document" in r.json()["detail"].lower()
    cid = create_case_with_docs(client)
    r = client.post(f"/api/cases/{cid}/analysis", json={"argument_style": "maximum_challenge"})
    assert r.status_code == 409


def test_provider_unavailable_gives_actionable_error_not_fallback(tmp_path):
    from fastapi.testclient import TestClient

    from app.main import create_app

    settings = make_settings(tmp_path, inference_provider="hermes", hermes_base_url="http://127.0.0.1:9", hermes_api_key="k" * 20)
    app = create_app(settings)
    with TestClient(app) as client:
        health = client.get("/api/health").json()
        assert health["provider"]["provider"] == "hermes" and health["provider"]["is_real_inference"] is True
        inf = client.get("/api/health/inference").json()
        assert inf["ok"] is False and "unreachable" in inf["detail"].lower()
        cid = create_case_with_docs(client)
        run = run_analysis(client, cid)
        assert run["status"] == "failed"
        assert "Cannot connect" in run["error"] or "unreachable" in run["error"].lower()
        # nothing was substituted: no model stage output exists
        assert client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}/results").json().keys() == {"extraction_check"}
