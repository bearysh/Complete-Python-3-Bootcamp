# LITTLE GUY LEGAL — Milestone 1 Checkpoint

Checkpoint date: 2026-10-31. Branch: `claude/keen-cray-h6x98a`. App directory: `little-guy-legal/`.

## 1. Project status (honest summary)
The complete single-case workflow is implemented, tested and documented: case creation, PDF/DOCX
upload with local extraction and stable source locators, minimal intake with document-derived
suggestions, a durable eight-stage analysis state machine with per-stage persistence and resume,
five specialist roles with schema-validated structured outputs, an independent verification
service, a human approval flow, and a professional PDF + JSON report. The frontend is a polished
dependency-free web UI served on localhost. 44 backend/security tests and a browser end-to-end
test pass. A verified starter corpus of 36 Texas statute sections is included with provenance.

**What is NOT done:** the development environment was a Linux cloud container without the Mac
mini's Hermes, OMLX or Qwen. Therefore:
* Acceptance criterion 4 (genuine local Hermes/Qwen inference) and criterion 10's benchmark
  numbers are **not verified**. The acceptance run committed under
  `docs/acceptance/scripted-dev-container/` used the double-gated *scripted test provider*
  (canned fixture outputs). Its report PDF is a template/plumbing demonstration, not model output,
  and it says so on its cover and in its metadata.
* The Hermes profile and `hermes/verify_profile.py` live checks have not been executed against a
  real Hermes install; the adapter was validated against a loopback fake built from the 0.19.0 source.
* The authority library was fetched through a retrieval service rather than directly from the
  publisher; `scripts/build_authority_library.py --verify` must be run on the Mac mini.

Everything required to close those gaps is scripted: see §9 "Exact commands to resume".

## 2. Implemented functionality (mapped to the Definition of Done)
| # | Requirement | Status |
|---|---|---|
| 1–2 | Launch on Mac mini, polished localhost UI | Implemented (`scripts/start.sh`, `frontend/`); screenshots in `docs/screenshots/` |
| 3 | Create a case | ✅ |
| 4 | Upload PDF/DOCX lease and supporting docs | ✅ content-sniffed, read-only originals, SHA-256, page/paragraph locators, FTS index |
| 5 | Essential intake questions | ✅ five questions + pattern-matched suggestions with refs |
| 6 | Start analysis via local Hermes/Qwen | Implemented (`inference/hermes.py`); **not exercised against real Hermes here** |
| 7 | Observe progress through specialist stages | ✅ stage stepper, no invented percentages, cancel/resume |
| 8 | Review issues, references, competing arguments, uncertainties | ✅ 12-tab review screen |
| 9 | Inspect citations and source passages | ✅ evidence drawer with quote highlighting; authority drawer with provenance |
| 10 | Approve/reject draft | ✅ reviewer name + timestamp; material failures require acknowledgement |
| 11 | Export professional PDF | ✅ reportlab template, 15 required sections, status banner every page, JSON alongside |
| 12 | Close/reopen without loss | ✅ SQLite authoritative; interrupted runs resume from last completed stage (tested) |

## 3. Repository structure
```
little-guy-legal/
  app/            FastAPI app: api/ routes, services/ (cases, documents, extraction, intake, authority,
                  prompts, pipeline, verification, report, pdf), inference/ (egress, hermes, omlx, scripted),
                  models/ (Pydantic schemas), db.py, config.py, main.py
  frontend/       index.html, css/app.css, js/ (router, api, views/*, evidence drawer)
  library/        README + sources/*.json (official Texas statute text with provenance)
  hermes/         little-guy-legal.config.yaml, env.example, setup_profile.sh, verify_profile.py
  fixtures/       synthetic/ (generate.py, files/, expected_findings.json), scripted_responses/{default,fabricated}
  scripts/        install.sh, start.sh, stop.sh, backup_restore.sh, run_acceptance.py, evaluate.py,
                  benchmark.py, build_authority_library.py
  tests/          pytest suite (44 tests) + e2e/ Playwright smoke test
  docs/           SETUP, ARCHITECTURE, SECURITY, HERMES_INTEGRATION, ENVIRONMENT_DISCOVERY, API,
                  screenshots/, acceptance/scripted-dev-container/
```

## 4. Important design decisions
* Short mechanical evidence refs (`D1:p4`, `D2:para12`, `A:tx-prop-93.002`) that small models can
  emit reliably and the verifier can resolve exactly.
* Explicit state machine (`services/pipeline.py`) with per-stage persistence; no orchestration framework.
* One provider chosen at startup; loopback enforced at construction and per request; no fallback.
* Fresh random Hermes session per stage (`X-Hermes-Session-Id`), recorded for cleanup; the app DB is authoritative.
* Documents enter prompts as delimited untrusted evidence with angle brackets neutralized; the
  Hermes profile exposes no tools, so injected instructions have nothing to act on.
* Verification is application code, not a model; material failures block approval unless acknowledged.
* Scripted provider double-gated (`LGL_INFERENCE_PROVIDER=scripted` + `LGL_ALLOW_SCRIPTED_PROVIDER=1`),
  labelled in health, UI banner, report cover and metadata.
* Vanilla JS frontend (no build step) to keep Mac mini setup to Python only.
* Application code lives in a subdirectory of the provided tutorial repository; recommend extracting
  it into its own repository at the start of Milestone 2.

## 5. Hermes / OMLX integration details
* Verified against `hermes-agent==0.19.0` source (see `docs/HERMES_INTEGRATION.md`): API server is
  started by `hermes -p little-guy-legal gateway run`, binds 127.0.0.1:8642, requires a ≥16-char
  `API_SERVER_KEY` in the profile `.env`, speaks OpenAI-style `/v1/chat/completions`, takes the
  session id from `X-Hermes-Session-Id`, and loads toolsets only from profile config.
* Profile template disables memory, user-profile memory, memory plugins, all tool families, MCP,
  skill nudges/curator, fallback providers and the model catalog; auxiliary tasks pinned to loopback.
* App env: `LGL_INFERENCE_PROVIDER=hermes`, `LGL_HERMES_BASE_URL=http://127.0.0.1:8642`,
  `LGL_HERMES_API_KEY=<profile key>`. Diagnostic direct path: `LGL_INFERENCE_PROVIDER=omlx` with
  `LGL_OMLX_BASE_URL` and the exact `LGL_OMLX_MODEL` id.
* Exact OMLX endpoint/model ids are unknown until discovered on the Mac mini (`setup_profile.sh` does this).

## 6. Test and evaluation results (development container)
* `pytest`: 44 passed (extraction, config/egress, JSON parsing, authority/verification incl.
  fabricated-citation rejection, workflow incl. restart/resume, Hermes adapter contract, security).
* `tests/e2e/run.sh` (Playwright/Chromium): passes — create case, upload, intake, analysis, review,
  evidence drawer, report approval; no console errors.
* `scripts/run_acceptance.py` with scripted provider: 12/13 checks pass; the failing check is
  "real local inference provider configured" (expected here). Scorecard
  (`docs/acceptance/scripted-dev-container/scorecard.json`): document citation accuracy 66/66,
  expected authorities 3/3 found, 0 fabricated accepted, major issues 5/5, missing evidence 4/4,
  arguments materially different, no forbidden certainty phrases. These numbers describe the
  *fixture*, not any model; they validate the pipeline, verifier and scorecard tooling only.
* Benchmarks: **none** (no local model available). `scripts/benchmark.py` is ready.

## 7. Known defects and gaps
* No real-model run yet; prompt sizes and JSON-compliance of Qwen 27B/35B-A3B outputs are untested.
  Expect to tune `LGL_MAX_OUTPUT_TOKENS`, `LGL_MAX_EVIDENCE_CHARS`, repair attempts and possibly
  prompt wording after the first live runs.
* Hermes ignores per-request `max_tokens`/`temperature`; the profile's `model.max_tokens` must be
  large enough (6000 set) for the Knowledge stage output.
* OCR requires Tesseract on the Mac mini; otherwise scanned pages are flagged unreadable.
* Consistency checking (amounts/dates vs. cited passage) is heuristic and only warns.
* PDF iframe preview does not render in headless Chromium (download link works); fine in Safari/Chrome.
* `DocKind` includes `photo`/`unknown` that the UI select does not offer (shown as-is).
* The authority corpus has statutes only; no TRCP, case law, or Tarrant County local rules.
* Argument style `maximum_challenge` is deferred (schema and prompt scaffold exist).

## 8. Privacy limitations (see docs/SECURITY.md)
* Application-level egress control is enforced and tested; OS/network-level containment of Hermes
  and OMLX processes is **not** implemented or verified (sample pf anchor provided, untested).
* Hermes tool/memory disablement is based on 0.19.0 source review plus live `verify_profile.py`
  checks that have not yet been run on the Mac mini.
* Running the app as root on Linux bypasses file read-only protection; run as a normal user.

## 9. Exact commands to resume development (Mac mini)
```bash
git clone <repo> && cd <repo>/little-guy-legal && git checkout claude/keen-cray-h6x98a
bash scripts/install.sh
bash hermes/setup_profile.sh                 # discovers OMLX, writes isolated profile + key
grep API_SERVER_KEY ~/.hermes/profiles/little-guy-legal/.env | sed 's/API_SERVER_KEY/LGL_HERMES_API_KEY/' >> .env
hermes -p little-guy-legal gateway run       # terminal 2
python hermes/verify_profile.py              # all PASS required
python scripts/benchmark.py --n 3            # first real latency/token numbers
bash scripts/start.sh                        # terminal 3; open http://127.0.0.1:8765
python scripts/run_acceptance.py             # full synthetic case with real Qwen; artifacts in docs/acceptance/
python scripts/build_authority_library.py --verify
python -m pytest -q && bash tests/e2e/run.sh
```
Then commit the real `docs/acceptance/` artifacts and benchmark JSON, and update §6 of this file.

## 10. Recommended Milestone 2 scope
1. Close the M1 verification gaps above on the Mac mini (real inference, benchmarks, profile checks, pf rules).
2. Prompt/parameter tuning per model; add a per-stage model routing option (e.g. 27B for Knowledge, A3B for drafts).
3. Expand the authority library: TRCP Part V (justice court/eviction), Tarrant County JP local rules,
   selected Texas appellate opinions from official sources, with the same provenance scheme.
4. OCR (Tesseract) install and scanned-document tests; image/photo evidence.
5. Multi-document timeline reconciliation and contradiction detection beyond heuristics.
6. `maximum_challenge` style; operator-editable report notes before approval.
7. Attorney-reviewed evaluation set and scorecard calibration before any accuracy claims.
8. Move to a dedicated repository; launchd services for Hermes and the app; backup automation.
