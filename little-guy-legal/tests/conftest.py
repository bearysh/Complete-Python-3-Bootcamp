from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
FIXTURES = ROOT / "fixtures" / "synthetic" / "files"
SCRIPTED = ROOT / "fixtures" / "scripted_responses"


def make_settings(tmp_path: Path, **overrides):
    from app.config import Settings

    base = dict(data_dir=tmp_path / "data", inference_provider="scripted", allow_scripted_provider=True,
                scripted_responses_dir=SCRIPTED, hermes_api_key="test-key-not-a-secret-0000", _env_file=None)
    base.update(overrides)
    return Settings(**base)


@pytest.fixture
def settings(tmp_path):
    return make_settings(tmp_path)


@pytest.fixture
def client(settings):
    from fastapi.testclient import TestClient

    from app.main import create_app

    app = create_app(settings)
    with TestClient(app) as c:
        yield c


def upload_fixture_docs(client, case_id: str, names=("01_commercial_lease.pdf", "02_notice_of_default.docx", "03_email_chain.docx")):
    out = []
    for name in names:
        with open(FIXTURES / name, "rb") as fh:
            r = client.post(f"/api/cases/{case_id}/documents", files={"file": (name, fh)})
        assert r.status_code == 201, r.text
        out.append(r.json())
    return out


INTAKE = {
    "user_role": "tenant",
    "narrative": "Landlord changed our locks on August 26 after we withheld August rent to cover an $8,400 HVAC compressor replacement.",
    "desired_outcome": "Regain possession and recover the repair cost.",
    "key_dates": [{"label": "Lockout", "date": "2025-08-26", "confirmed": True}],
    "prior_notices": [{"kind": "notice of default", "date": "2025-08-11", "description": "letter by email"}],
}


def create_case_with_docs(client, title="Synthetic case"):
    cid = client.post("/api/cases", json={"title": title}).json()["id"]
    upload_fixture_docs(client, cid)
    client.put(f"/api/cases/{cid}/intake", json=INTAKE)
    return cid


def run_analysis(client, cid: str, style="by_the_book", timeout=60):
    r = client.post(f"/api/cases/{cid}/analysis", json={"argument_style": style})
    assert r.status_code == 202, r.text
    run_id = r.json()["id"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        run = client.get(f"/api/cases/{cid}/analysis/runs/{run_id}").json()
        if run["status"] in ("completed", "failed", "cancelled", "interrupted"):
            return run
        time.sleep(0.1)
    raise AssertionError("analysis did not finish in time")
