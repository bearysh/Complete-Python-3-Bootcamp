# Little Guy Legal — Milestone 1

Local-first, multi-agent legal research and document-review application for Texas
commercial lease disputes (initial focus: Tarrant County). It helps a small-business
owner understand their lease and dispute before consulting a licensed attorney.
It is **not** a law firm, provides no legal representation, and labels every output
"AI-Assisted Legal Research — For Attorney Review".

* Backend: Python 3.11+, FastAPI, SQLite (FTS5), Pydantic, PyMuPDF, python-docx, reportlab.
* Frontend: dependency-free vanilla JavaScript served by FastAPI (no build step).
* Inference: **only** local models, through the Hermes Agent API server (dedicated
  `little-guy-legal` profile) → OMLX → Qwen. No cloud fallback exists in the code.
* Case data lives outside the repository (`LGL_DATA_DIR`, default `~/LittleGuyLegal/data`).

Start here:

| Need | Read |
|---|---|
| Install, start, stop, test, back up on the Mac mini | [docs/SETUP.md](docs/SETUP.md) |
| Hermes profile creation and verification | [docs/HERMES_INTEGRATION.md](docs/HERMES_INTEGRATION.md) |
| Architecture, data flow, storage layout | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Privacy boundaries and what is / is not verified | [docs/SECURITY.md](docs/SECURITY.md) |
| What the development environment could and could not do | [docs/ENVIRONMENT_DISCOVERY.md](docs/ENVIRONMENT_DISCOVERY.md) |
| HTTP API | [docs/API.md](docs/API.md) |
| Project status and how to resume | [LITTLE_GUY_LEGAL_M1_CHECKPOINT.md](LITTLE_GUY_LEGAL_M1_CHECKPOINT.md) |

Quick start (Mac mini):

```bash
bash scripts/install.sh                       # venv + pinned dependencies + .env
bash hermes/setup_profile.sh                  # isolated Hermes profile (needs OMLX running)
hermes -p little-guy-legal gateway run        # in a second terminal: local Hermes API server
python hermes/verify_profile.py               # confirm memory/tools are off and the server is loopback-only
bash scripts/start.sh                         # app at http://127.0.0.1:8765
```

Run the synthetic acceptance case end to end: `python scripts/run_acceptance.py`.
