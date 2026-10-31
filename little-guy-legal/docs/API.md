# Little Guy Legal — HTTP API (Milestone 1)

Base URL: `http://127.0.0.1:8765`. All responses JSON unless noted. Interactive docs at `/api/docs`.

## System
- `GET /api/health` → `{status, data_dir, provider:{configured, provider, label, endpoint, model, is_real_inference, notes|error}, warnings[], authority_library_size}`
- `GET /api/health/inference` → provider-specific health (`ok`, `detail`, `models`, …)
- `GET /api/authorities?q=` → list (or search) library entries; `GET /api/authorities/{id}` → full text + provenance

## Cases
- `POST /api/cases {title, county?}` → CaseOut (201)
- `GET /api/cases` → CaseOut[]; `GET /api/cases/{id}`; `DELETE /api/cases/{id}` (409 if analysis running)
- CaseOut: `{id,title,status,jurisdiction,county,matter_type,created_at,updated_at,document_count,has_intake,latest_run_id,latest_run_status,latest_report_id,latest_report_status}`
  status ∈ intake | analyzing | analyzed | report_draft | report_approved | report_rejected
- `GET /api/cases/{id}/audit` → `[{ts,event,detail}]`

## Documents
- `POST /api/cases/{id}/documents` multipart field `file` (.pdf/.docx, ≤50MB) → DocumentOut (201; 415 unsupported)
- `GET /api/cases/{id}/documents` → DocumentOut[]; `PATCH /api/cases/{id}/documents/{docId} {doc_kind}`; `DELETE …/{docId}`
- DocumentOut: `{id,case_id,ordinal,ref_prefix (D1…),filename,mime,doc_kind,size_bytes,sha256,uploaded_at,extraction_status (pending|extracted|failed),extraction_error,page_count,segment_count,unreadable_pages[]}`
- `GET /api/cases/{id}/documents/{docId}/segments` → `[{id,document_id,ref,locator_type,page_number,paragraph_index,section_label,text}]`
- `GET /api/cases/{id}/documents/{docId}/original` → file download
- `GET /api/cases/{id}/segments/{ref}` → one segment by ref (e.g. `D1:p4`, `D2:para12`); 404 if not in this case
- `GET /api/cases/{id}/search?q=` → `[{id,ref,document_id,section_label,snippet}]`

## Intake
- `GET /api/cases/{id}/intake` → IntakeData | null
- `PUT /api/cases/{id}/intake` IntakeData → IntakeData
- IntakeData: `{user_role: landlord|tenant|guarantor|other|unknown, narrative, desired_outcome, key_dates:[{label,date,confirmed}], prior_notices:[{kind,date,description}], confirmed_inferences:{}}`
- `GET /api/cases/{id}/intake/suggestions` → `{parties:{role:{name,ref}}, dates:[{date,context,ref,document}], amounts:[…], notice_indicators:[…], note}` (pattern-matched, not AI)

## Analysis
- `POST /api/cases/{id}/analysis {argument_style: by_the_book|aggressive}` → Run (202; 409 with message if cannot start)
- `GET /api/cases/{id}/analysis` → latest Run or `{status:"none", stages:[]}`
- `GET /api/cases/{id}/analysis/runs` → Run summaries; `GET …/runs/{runId}` → Run
- `POST …/runs/{runId}/cancel`; `POST …/runs/{runId}/resume` (202)
- `GET …/runs/{runId}/results` → `{extraction_check, knowledge, advocate_customer, advocate_opposing, judge, senior_partner, verification, report_draft}` (only completed stages present)
- Run: `{id,case_id,status: queued|running|completed|failed|cancelled|interrupted, current_stage, provider, model, argument_style, started_at, finished_at, error, stages:[{stage,label,status: pending|running|completed|failed|cancelled, attempt, started_at, finished_at, duration_ms, prompt_tokens, completion_tokens, error, session_id}]}`
- Stage order: extraction_check, knowledge, advocate_customer, advocate_opposing, judge, senior_partner, verification, report_draft. No percentages are reported; show stage states only.

## Reports
- `GET /api/cases/{id}/reports` → `[{id,case_id,run_id,version,status: draft|approved|rejected,json_path,pdf_path,created_at,reviewed_at,reviewer,reviewer_action,reviewer_note,acknowledged_failures}]`
- `GET /api/cases/{id}/reports/{rid}` → `{meta, data}` where data is the full report JSON (sections: scope_and_limitations, executive_summary, background_and_timeline{facts,timeline,parties}, key_lease_provisions, legal_authorities, main_legal_issues, legal_questions, customer_arguments, opposing_arguments, skeptical_analysis, missing_information, time_sensitive_concerns, practical_considerations, questions_for_attorney, unverified_claims, caveats, verification{checks,summary,material_failure,notes,limitations}, evidence_appendix, metadata, review)
- `POST /api/cases/{id}/reports/{rid}/review {action: approve|reject, reviewer, note?, acknowledge_verification_failures?}` → report meta (409 if material failures unacknowledged; 400 if already reviewed)
- `GET /api/cases/{id}/reports/{rid}/pdf` → PDF download; `GET …/json` → JSON download

Stage output schemas: see `app/models/stages.py`. Evidence refs look like `{ref:"D1:p4", quote:"…"}` or `{ref:"A:tx-prop-93.002", quote}`.
