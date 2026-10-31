# Privacy and Security Boundaries

## What is enforced in software (and tested)
| Control | Mechanism | Test |
|---|---|---|
| Case inference only on loopback | `app/inference/egress.py`: base URL validated at provider construction; httpx client `trust_env=False`, no redirects, request hook re-checks every URL | `test_config_and_egress.py`, `test_security.py::test_non_loopback_destinations_fail_closed` |
| No cloud fallback | exactly one provider is built from config; no retry on another provider; unavailable → run fails with actionable error | `test_workflow.py::test_provider_unavailable_gives_actionable_error_not_fallback`, `test_security.py::test_cloud_fallback_is_impossible_when_local_provider_down` |
| No remote connections during processing | socket-level spy during a full run | `test_security.py::test_case_processing_never_contacts_remote_hosts` |
| App binds to localhost | `Settings.host` validator rejects non-loopback | `test_config_and_egress.py::test_host_must_be_loopback` |
| Hermes memory/tools off | profile template asserts + `hermes/verify_profile.py` live checks | `test_security.py::test_hermes_profile_template_disables_memory_and_tools` |
| Session isolation | random `X-Hermes-Session-Id` per stage; ids recorded; cleanup by retention | `test_workflow.py::test_full_workflow_persists_and_approves`, `test_hermes_adapter.py` |
| Case isolation | every query scoped by `case_id`; refs resolve only within the case; a new case's prompt contains no other case content | `test_security.py::test_one_case_cannot_read_another_cases_evidence_or_transcripts` |
| Secrets never logged | `SecretStr` settings; redacting log filter (Bearer, key=value, sk- tokens) | `test_security.py::test_secrets_never_appear_in_logs_or_reports` |
| Uploads are data | content sniffing, filename sanitization, no execution path, documents wrapped as delimited evidence with angle brackets neutralized | `test_security.py::test_uploaded_content_is_data_not_commands` |
| Originals immutable | read-only mode bits + macOS `UF_IMMUTABLE`; SHA-256 recorded and re-checkable | `test_security.py::test_original_files_cannot_be_modified_after_upload` |
| Fabricated citations rejected | verifier rejects unknown authority ids, unknown documents, mismatched quotes; blocks approval without acknowledgement | `test_authority_and_verification.py::test_verification_rejects_fabrications` |
| Human approval | reports are `draft` until a named reviewer acts; PDF banner reflects status | `test_workflow.py` |

## Prompt injection
Documents are untrusted. Mitigations: the Hermes profile exposes **no tools**, so injected
"tool calls" have nothing to invoke; outputs must match strict schemas and are never executed
or interpreted as commands; documents are delimited and the system prompt forbids following
them; the injection fixture (`fixtures/synthetic/files/injection_test_document.docx`) is part of
the test suite. What is **not** tested here: whether a given Qwen model's *content* is swayed by
injected text. That requires running `tests/` and the fixture on the Mac mini with real
inference and reading the outputs; the verifier will at least reject fabricated authorities
(e.g. the fixture's "Section 999.999").

## Not enforced by this application (documented limitations)
* **Network-level containment.** Nothing in the app prevents *other* processes (Hermes, OMLX,
  macOS services) from reaching the internet. For a verified guarantee, add OS-level egress
  rules (for example a `pf` anchor that blocks outbound traffic from the Hermes and OMLX
  processes/users except loopback, or run both behind a firewall profile). A sample anchor is
  outlined below but was **not** tested in this milestone.
* **Hermes internals.** The profile config disables memory, tools, skills, fallback and the
  model catalog based on source review of 0.19.0. `verify_profile.py` checks the live server's
  reported toolsets, but the only complete proof is observing network traffic on the Mac mini
  (e.g. `sudo lsof -i -P | grep -E 'hermes|omlx'` or a packet capture during a run).
* **Running as root** defeats the read-only file protection on Linux (tests account for this);
  run the app as a normal user.
* **Browser**: the UI is served without authentication because it binds to loopback only. Do
  not change `LGL_HOST` without adding authentication and TLS.
* **Disk encryption** and backups are the operator's responsibility (FileVault recommended).

### Sample pf anchor (untested; adapt before use)
```
# /etc/pf.anchors/littleguylegal — block all outbound traffic from the 'lgl' user except loopback
block out quick proto {tcp udp} from any to !127.0.0.0/8 user lgl
pass out quick on lo0 user lgl
```
Run Hermes and OMLX as that dedicated user to make the rule meaningful.

## Data locations and retention
See `docs/SETUP.md` §9. Deleting a case removes its DB rows (cascade), its directory, and its
FTS entries. Hermes transcripts are deleted by `cleanup_expired_sessions()` after
`LGL_SESSION_RETENTION_DAYS` (default 30; set 0 to delete at next startup) and by the profile's
own `sessions.auto_prune`.
