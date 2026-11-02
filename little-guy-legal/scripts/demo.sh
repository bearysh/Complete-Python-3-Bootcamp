#!/usr/bin/env bash
# One-command Milestone 1 demo on the Mac mini. Safe to re-run.
#   bash scripts/demo.sh
# Steps: install → discover OMLX → create/refresh the isolated Hermes profile → start the Hermes
# gateway (background) → verify the profile → start the app (background) → run the synthetic
# acceptance case with REAL local inference → open the case in the browser.
# Never modifies the personal Hermes profile. Logs go to LGL_DATA_DIR/demo-logs/.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE=little-guy-legal
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

step "1/7 Install application dependencies"
bash scripts/install.sh

set -a; . ./.env; set +a
DATA="${LGL_DATA_DIR:-$HOME/LittleGuyLegal/data}"; DATA="${DATA/#\~/$HOME}"
mkdir -p "$DATA/demo-logs"
LOGS="$DATA/demo-logs"

step "2/7 Discover OMLX on loopback"
OMLX_URL="${LGL_OMLX_BASE_URL:-}"
if [ -z "$OMLX_URL" ] || ! curl -s -m 3 "${OMLX_URL%/}/v1/models" >/dev/null 2>&1; then
  OMLX_URL=""
  for port in 8000 8080 1234 11434 5000 8888 10240; do
    if curl -s -m 2 "http://127.0.0.1:$port/v1/models" | grep -q '"data"'; then OMLX_URL="http://127.0.0.1:$port"; break; fi
  done
fi
[ -n "$OMLX_URL" ] || { echo "OMLX is not serving /v1/models on any common loopback port. Start OMLX, then re-run."; exit 1; }
MODELS="$(curl -s -m 5 "${OMLX_URL%/}/v1/models" | python3 -c 'import sys,json; print("\n".join(m["id"] for m in json.load(sys.stdin)["data"]))')"
echo "OMLX at $OMLX_URL serves:"; echo "$MODELS" | sed 's/^/   /'
MODEL="${LGL_OMLX_MODEL:-}"
if [ -z "$MODEL" ] || ! echo "$MODELS" | grep -qx "$MODEL"; then
  # Prefer the larger dense Qwen for quality; fall back to the first model.
  MODEL="$(echo "$MODELS" | grep -i -E 'qwen' | grep -i -E '27b|32b' | head -1 || true)"
  [ -n "$MODEL" ] || MODEL="$(echo "$MODELS" | head -1)"
fi
echo "Using model: $MODEL"
grep -q '^LGL_OMLX_BASE_URL=' .env && sed -i.bak "s#^LGL_OMLX_BASE_URL=.*#LGL_OMLX_BASE_URL=${OMLX_URL}#" .env || echo "LGL_OMLX_BASE_URL=${OMLX_URL}" >> .env
grep -q '^LGL_OMLX_MODEL=' .env && sed -i.bak "s#^LGL_OMLX_MODEL=.*#LGL_OMLX_MODEL=${MODEL}#" .env || echo "LGL_OMLX_MODEL=${MODEL}" >> .env

step "3/7 Create or refresh the isolated Hermes profile '$PROFILE'"
bash hermes/setup_profile.sh "${OMLX_URL%/}/v1" "$MODEL"
PROFILE_DIR="$HOME/.hermes/profiles/$PROFILE"
KEY="$(grep '^API_SERVER_KEY=' "$PROFILE_DIR/.env" | cut -d= -f2-)"
grep -q '^LGL_HERMES_API_KEY=' .env && sed -i.bak "s#^LGL_HERMES_API_KEY=.*#LGL_HERMES_API_KEY=${KEY}#" .env || echo "LGL_HERMES_API_KEY=${KEY}" >> .env
sed -i.bak "s#^LGL_INFERENCE_PROVIDER=.*#LGL_INFERENCE_PROVIDER=hermes#" .env
rm -f .env.bak

step "4/7 Start the Hermes gateway API server for '$PROFILE' (loopback only)"
if curl -s -m 2 http://127.0.0.1:8642/v1/health >/dev/null; then
  echo "A Hermes API server is already listening on 8642; reusing it (make sure it is the $PROFILE profile)."
else
  nohup hermes -p "$PROFILE" gateway run > "$LOGS/hermes-gateway.log" 2>&1 &
  echo $! > .hermes.pid
  for i in $(seq 1 60); do curl -s -m 2 http://127.0.0.1:8642/v1/health >/dev/null && break; sleep 1; done
  curl -s -m 2 http://127.0.0.1:8642/v1/health >/dev/null || { echo "Hermes API server did not come up; see $LOGS/hermes-gateway.log"; tail -30 "$LOGS/hermes-gateway.log"; exit 1; }
fi

step "5/7 Verify the effective Hermes profile configuration"
set -a; . ./.env; set +a
.venv/bin/python hermes/verify_profile.py | tee "$LOGS/verify_profile.txt" || { echo "Profile verification failed — not starting the demo with an unverified profile."; exit 1; }

step "6/7 Start Little Guy Legal and benchmark the inference path"
bash scripts/stop.sh >/dev/null 2>&1 || true
bash scripts/start.sh --background
for i in $(seq 1 40); do curl -s -m 2 "http://127.0.0.1:${LGL_PORT:-8765}/api/health" >/dev/null && break; sleep 0.5; done
curl -s "http://127.0.0.1:${LGL_PORT:-8765}/api/health/inference" | tee "$LOGS/inference-health.json"; echo
.venv/bin/python scripts/benchmark.py --n 2 --out docs/benchmarks/latest.json | tee "$LOGS/benchmark.txt"

step "7/7 Run the synthetic case end to end with real local inference"
.venv/bin/python scripts/run_acceptance.py --base "http://127.0.0.1:${LGL_PORT:-8765}" --out docs/acceptance/mac-mini-real-inference | tee "$LOGS/acceptance.txt"
CASE_ID="$(cat docs/acceptance/mac-mini-real-inference/case_id.txt 2>/dev/null || true)"
URL="http://127.0.0.1:${LGL_PORT:-8765}/cases/${CASE_ID}/review"
echo; echo "Demo ready: $URL"
command -v open >/dev/null && open "$URL" || true
