# Architecture

## Service diagram
```
┌──────────────────────────── Mac mini (all loopback) ─────────────────────────────┐
│  Browser ──HTTP 127.0.0.1:8765──▶ FastAPI app (app/)                               │
│                                   ├─ api/        routes (cases, documents, intake,│
│                                   │              analysis, reports, system)        │
│                                   ├─ services/   cases · documents · extraction    │
│                                   │              intake · authority · prompts      │
│                                   │              pipeline (state machine)          │
│                                   │              verification · report · pdf       │
│                                   ├─ inference/  egress guard · hermes · omlx      │
│                                   │              scripted(test) · json_utils       │
│                                   └─ SQLite  LGL_DATA_DIR/lgl.sqlite3 (+ files)    │
│                                            │                                       │
│      primary: ──HTTP 127.0.0.1:8642──▶ Hermes gateway API server (profile          │
│                                        little-guy-legal, tools+memory disabled)     │
│                                            │ custom provider, loopback             │
│      diagnostic: ─HTTP 127.0.0.1:<port>─▶ OMLX OpenAI-compatible server ─▶ Qwen    │
└───────────────────────────────────────────────────────────────────────────────────┘
No component opens a connection to any non-loopback host during case processing.
```

## Data flow for one case
1. **Create case** → row in `cases`; directory `cases/<id>/{originals,extracted,transcripts,reports}`.
2. **Upload** → content sniffed (PDF magic / DOCX zip structure), stored read-only with SHA-256,
   extracted locally (PyMuPDF per page / python-docx per paragraph + tables), segments inserted
   with stable refs `D{n}:p{page}` or `D{n}:para{i}` and indexed in FTS5. Unreadable scanned pages
   are flagged (OCR only if Tesseract exists locally).
3. **Intake** → five essential questions stored as JSON; pattern-matched suggestions (parties,
   dates, amounts, notice indicators) with source refs for confirmation. Not AI.
4. **Analysis run** (`analysis_runs` + `stage_executions`), strictly sequential:
   `extraction_check → knowledge → advocate_customer → advocate_opposing → judge → senior_partner → verification → report_draft`.
   Each model stage: build prompts (documents as delimited untrusted evidence, library index,
   keyword-selected statute text) → one request to the provider with a fresh unpredictable
   `X-Hermes-Session-Id` → extract JSON → validate against the Pydantic schema → up to two repair
   rounds → persist `output_json` and raw transcript **before** the next stage starts.
   Advocates receive the same Knowledge packet and never see each other's output; the Judge sees
   both; the Senior Partner sees everything.
5. **Verification** (application code, no model): resolves every evidence ref to stored text,
   checks quotes (exact / 5-gram fuzzy), rejects unknown authority ids, flags findings without
   evidence, checks amounts/dates in findings against cited passages. Material failures block
   approval unless the operator explicitly acknowledges them.
6. **Report** → JSON (machine-readable) + PDF (reportlab template with status banner on every page,
   "Page X of Y", evidence appendix with excerpts and verification status, metadata). Draft until a
   reviewer action is recorded; approval regenerates the PDF with the approval stamp.
7. **Restart** → runs left `running` are marked `interrupted`; `resume` re-executes only stages that
   have no completed output.

## Key design decisions
* **Short evidence refs** (`D1:p4`, `A:tx-prop-93.002`) instead of free-form citations: small local
  models cite them reliably and the verifier resolves them mechanically.
* **Per-stage sessions, not one conversation**: isolation between stages and cases; every session
  id is random and recorded in `stage_executions.session_id` for cleanup.
* **The app database is authoritative.** Hermes `state.db` is treated as a disposable cache.
* **Fail closed.** The provider is chosen once at startup from configuration; non-loopback URLs
  raise before any request; an unavailable provider fails the run with an actionable message.
* **Scripted test provider** exists so the full pipeline, verifier, report and UI can be tested
  without a GPU. It is double-gated and labelled everywhere; it is not part of the completion path
  when `LGL_INFERENCE_PROVIDER=hermes`.
* **No orchestration framework.** A ~400-line controller with explicit statuses is enough for one
  machine and is easy to audit.
* **Vanilla JS frontend** served by FastAPI: no Node toolchain is needed on the Mac mini.

## Model configuration
* Hermes profile `little-guy-legal` → `model.provider: custom`, `base_url: http://127.0.0.1:<omlx>/v1`,
  `default: <exact OMLX model id>` (set by `hermes/setup_profile.sh` from `GET /v1/models`).
* App: `LGL_MAX_OUTPUT_TOKENS` (6000), `LGL_MAX_EVIDENCE_CHARS` (60000 ≈ 15k tokens of documents),
  `LGL_REQUEST_TIMEOUT_SECONDS` (900), `LGL_MAX_RETRIES` (2), `LGL_TEMPERATURE` (0.2).
  Generation parameters sent in the body are honoured by OMLX (direct path) but ignored by Hermes,
  whose profile `model.max_tokens` governs.
* Context budget per stage (approximate, synthetic fixture): Knowledge ≈ 12k input tokens
  (documents + 14 statutes + schema); later stages ≈ 8–14k. Qwen3 35B-A3B and 27B models with
  ≥32k context fit; `LGL_MAX_EVIDENCE_CHARS` truncates proportionally and records a caveat if exceeded.

## Extensibility hooks for later milestones
* Jurisdictions/specialties: `cases.jurisdiction`, `cases.matter_type`, `authorities.jurisdiction`,
  `binding_scope`; prompts are built per stage in `services/prompts.py`.
* Argument styles: `maximum_challenge` is already in the schema and prompt table (disabled in the API).
* Authority types: `authority_type` supports `statute | rule | opinion | regulation`; the loader
  currently splits statutory chapters only.
