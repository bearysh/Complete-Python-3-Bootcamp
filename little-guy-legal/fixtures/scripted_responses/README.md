# Scripted stage responses (TEST FIXTURES ONLY)

These JSON files are canned outputs for the five model stages, written by hand
for the synthetic Ridgmar Crossing / Brazos Bend Coffee fixture. They let the
automated test suite exercise the full pipeline (schema validation,
verification, report generation, approval flow, resume behavior) in an
environment without the Mac mini's local Qwen models.

They are **not** model output and are never used unless the operator sets both
`LGL_INFERENCE_PROVIDER=scripted` and `LGL_ALLOW_SCRIPTED_PROVIDER=1`. Every
surface (health endpoint, UI banner, report cover and metadata) labels runs
made with them as test fixtures.

* `default/` — a plausible, well-cited analysis.
* `fabricated/` — the same analysis with deliberate defects (a non-existent
  statute, a misquoted passage, a reference to a document that is not in the
  case) used to prove the verifier rejects them.
