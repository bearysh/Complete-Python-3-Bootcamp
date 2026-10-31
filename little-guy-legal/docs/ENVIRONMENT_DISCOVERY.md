# Environment Discovery (Checkpoint 1)

Date: 2026-10-31. Performed by the development agent at the start of Milestone 1.

## Where development actually ran
The build prompt assumes development on the Mac mini. This session ran instead in a
**managed Linux cloud container** (Ubuntu 24.04, x86_64, 4 vCPU, 15 GB RAM, Python 3.13.18,
Node 22) with the repository `bearysh/Complete-Python-3-Bootcamp` checked out. Consequences:

| Expected on Mac mini | Found in this container | Handling |
|---|---|---|
| Hermes Agent install, profiles | none (`hermes` not on PATH, no `~/.hermes`) | Pulled `hermes-agent==0.19.0` from PyPI and read its source to derive the exact API/profile/config behaviour (`docs/HERMES_INTEGRATION.md`). Adapter contract tested against a loopback fake. |
| OMLX + Qwen models | none; MLX is Apple-silicon only; model hubs (huggingface.co, hf-mirror, ollama registry, modelscope) blocked by egress policy | No real local inference possible here. A double-gated scripted test provider exercises the full pipeline. **Acceptance criterion 4 ("local Hermes/Qwen inference genuinely used") is therefore NOT verified** and must be run on the Mac mini with `scripts/run_acceptance.py`. |
| Hermes docs site | DNS-blocked (`hermes-agent.nousresearch.com`) | Source code used as authority (preferred anyway). |
| Texas statute sites | direct HTTPS blocked by the container proxy; reachable through the Firecrawl retrieval tool | Official text retrieved via Firecrawl from `statutes.capitol.texas.gov` and stored with URL, date, hash; `scripts/build_authority_library.py --verify` re-checks from the Mac mini. |
| Tesseract OCR | not installed | OCR path implemented behind a runtime check; unreadable pages are flagged. |
| 48 GB unified memory, 2 TB NVMe | 15 GB RAM, ~30 GB free disk | Irrelevant for the scripted tests; benchmarks must be produced on the Mac mini. |

The model names given by the project owner ("qwen 3.6-35b-a3b-mlx-4bit", "qwen 3.8-27b-4bit")
could not be verified. `hermes/setup_profile.sh` reads the real ids from OMLX's `/v1/models`.

## Repository
No application repository existed. The app was created in `little-guy-legal/` inside the
provided repository on branch `claude/keen-cray-h6x98a`. Recommendation: move it to its own
repository at the start of Milestone 2 (the directory is self-contained).

## Dependencies chosen (pinned in requirements.txt)
fastapi 0.115.0, uvicorn 0.34.0, pydantic 2.10.6, pydantic-settings 2.7.1, httpx 0.28.1,
pymupdf 1.25.3, python-docx 1.1.2, reportlab 4.3.1, python-multipart 0.0.20, pyyaml 6.0.2,
pytest 8.3.4. SQLite 3.53 with FTS5 confirmed. No PostgreSQL/Redis/queues.
