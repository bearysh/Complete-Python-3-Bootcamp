# Setup and Operations (Mac mini)

All commands run from the `little-guy-legal/` directory.

## 1. Prerequisites
* macOS on Apple silicon with Python 3.11–3.13 (`python3 --version`).
* OMLX running and serving an OpenAI-compatible API on loopback (confirm with
  `curl http://127.0.0.1:<port>/v1/models`; note the exact model id).
* Hermes Agent installed (`hermes version`). The personal default profile is never modified.

## 2. Install
```bash
bash scripts/install.sh
```
Creates `.venv`, installs pinned dependencies from `requirements-dev.txt`, copies
`.env.example` to `.env`, and regenerates the synthetic fixture files.

## 3. Configure
Edit `.env`:
```
LGL_DATA_DIR=~/LittleGuyLegal/data          # case storage, outside the repo (external NVMe path is fine)
LGL_INFERENCE_PROVIDER=hermes
LGL_HERMES_BASE_URL=http://127.0.0.1:8642
LGL_HERMES_API_KEY=<value of API_SERVER_KEY from the profile .env>
LGL_HERMES_MODEL=                            # optional; Hermes uses the profile's model
LGL_REQUEST_TIMEOUT_SECONDS=900
```
Never set `LGL_ALLOW_SCRIPTED_PROVIDER` on the Mac mini except to run the automated test suite.

## 4. Hermes profile
```bash
bash hermes/setup_profile.sh [http://127.0.0.1:<omlx-port>/v1] [<exact-model-id>]
hermes -p little-guy-legal gateway run          # keep running in its own terminal (or a launchd agent later)
python hermes/verify_profile.py                 # must print all PASS
```
Details and the verified config keys: `docs/HERMES_INTEGRATION.md`.

## 5. Start / stop
```bash
bash scripts/start.sh                 # foreground, Ctrl-C to stop
bash scripts/start.sh --background    # background; then: bash scripts/stop.sh
open http://127.0.0.1:8765
```
Health: `curl http://127.0.0.1:8765/api/health` and `curl http://127.0.0.1:8765/api/health/inference`.

## 6. Test
```bash
. .venv/bin/activate
python -m pytest -q                               # 44 backend/security tests (uses the scripted test provider internally)
bash tests/e2e/run.sh                             # browser smoke test (needs Node + Playwright with Chromium)
python scripts/run_acceptance.py                  # full synthetic case through the live app with REAL local inference
python scripts/evaluate.py --case-id <id>         # scorecard for any completed run
python scripts/benchmark.py --n 3                 # latency / tokens-per-second / memory for the configured provider
```
Acceptance artifacts (PDF, JSON, scorecard) are written to `docs/acceptance/`.

## 7. Back up / restore
```bash
bash scripts/backup_restore.sh backup             # tar.gz of LGL_DATA_DIR
bash scripts/backup_restore.sh restore <file>     # stops the app, restores the data directory
```
Case data is confidential: keep backups on local encrypted storage only.

## 8. Authority library maintenance (no case data involved)
```bash
python scripts/build_authority_library.py --list
python scripts/build_authority_library.py --verify   # re-fetch official pages and report drift
python scripts/build_authority_library.py --reload   # rebuild the SQLite index after editing library/sources (app stopped)
```

## 9. Storage layout (`LGL_DATA_DIR`)
```
lgl.sqlite3                      cases, documents, segments (+FTS), intake, runs, stage outputs, reports, audit log, authority index
logs/app.log                     application log (secrets redacted; no document content)
cases/<case_id>/originals/       uploaded files, read-only (+ macOS immutable flag), SHA-256 recorded
cases/<case_id>/extracted/       extracted text with locators (JSON)
cases/<case_id>/transcripts/<run_id>/<stage>_attemptN.txt   raw model responses per stage
cases/<case_id>/reports/         report_vN.json, report_vN_draft.pdf, report_vN_approved.pdf / _rejected.pdf
```
Hermes session transcripts live in `~/.hermes/profiles/little-guy-legal/state.db` and are
pruned by the profile's `sessions.retention_days` and by the app's
`LGL_SESSION_RETENTION_DAYS` cleanup (DELETE /api/sessions/{id}) at startup.
