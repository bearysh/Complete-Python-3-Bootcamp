#!/usr/bin/env bash
# Start a throwaway server with the scripted provider, run the browser smoke test, stop the server.
set -euo pipefail
cd "$(dirname "$0")/../.."
DATA="$(mktemp -d)"
export LGL_DATA_DIR="$DATA" LGL_INFERENCE_PROVIDER=scripted LGL_ALLOW_SCRIPTED_PROVIDER=1 LGL_PORT=8767
.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8767 --log-level warning &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$DATA"' EXIT
for i in $(seq 1 40); do curl -s http://127.0.0.1:8767/api/health >/dev/null && break; sleep 0.25; done
LGL_E2E_BASE=http://127.0.0.1:8767 node tests/e2e/smoke.spec.cjs
