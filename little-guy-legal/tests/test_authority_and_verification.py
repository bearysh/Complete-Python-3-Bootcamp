import json
from pathlib import Path

from app.services.authority import split_source
from tests.conftest import ROOT, create_case_with_docs, run_analysis


def test_library_sources_have_provenance_and_hashes():
    for f in (ROOT / "library" / "sources").glob("*.json"):
        src = json.loads(f.read_text())
        for key in ("source_url", "retrieved_at", "retrieval_method", "currency_statement", "publisher"):
            assert src[key], f"{f.name} missing {key}"
        assert src["source_url"].startswith("https://statutes.capitol.texas.gov/")
        auths = split_source(src)
        assert auths and all(len(a["sha256"]) == 64 for a in auths)


def test_authority_search_and_quote_verification(client):
    hits = client.get("/api/authorities?q=lockout new key delinquent rent").json()
    assert hits and hits[0]["id"].startswith("tx-prop-93.")
    auth = client.get("/api/authorities/tx-prop-93.012").json()
    assert "A landlord may not assess a charge" in auth["text"]
    assert client.get("/api/authorities/tx-prop-999.999").status_code == 404


def test_verification_passes_on_well_cited_fixture(client):
    cid = create_case_with_docs(client)
    run = run_analysis(client, cid)
    assert run["status"] == "completed", run
    res = client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}/results").json()
    v = res["verification"]
    assert v["summary"]["total_checks"] > 50
    assert v["summary"]["fabricated_authority_refs"] == 0
    assert v["material_failure"] is False
    bad = [c for c in v["checks"] if c["status"] not in ("verified", "consistency_warning") and c["material"]]
    assert bad == []


def test_verification_rejects_fabrications(tmp_path):
    from fastapi.testclient import TestClient

    from app.inference.scripted import ScriptedProvider
    from app.main import create_app
    from tests.conftest import make_settings

    settings = make_settings(tmp_path)
    app = create_app(settings)
    with TestClient(app) as client:
        state = app.state.lgl
        state.pipeline._provider = ScriptedProvider(settings.scripted_responses_dir, variant="fabricated")
        cid = create_case_with_docs(client)
        run = run_analysis(client, cid)
        assert run["status"] == "completed"
        v = client.get(f"/api/cases/{cid}/analysis/runs/{run['id']}/results").json()["verification"]
        statuses = {(c["target"], c["status"]) for c in v["checks"]}
        assert v["material_failure"] is True
        assert v["summary"]["fabricated_authority_refs"] == 1
        assert ("knowledge.facts.F90", "quote_mismatch") in statuses
        assert ("knowledge.facts.F91", "unknown_document") in statuses
        assert ("knowledge.facts.F92", "no_evidence") in statuses
        # the report cannot be approved without acknowledging the failures
        rep = client.get(f"/api/cases/{cid}/reports").json()[0]
        r = client.post(f"/api/cases/{cid}/reports/{rep['id']}/review", json={"action": "approve", "reviewer": "Op"})
        assert r.status_code == 409
        r = client.post(f"/api/cases/{cid}/reports/{rep['id']}/review", json={"action": "approve", "reviewer": "Op", "acknowledge_verification_failures": True})
        assert r.status_code == 200 and r.json()["status"] == "approved" and r.json()["acknowledged_failures"] == 1
