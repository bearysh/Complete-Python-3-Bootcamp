#!/usr/bin/env bash
# Start the Little Guy Legal web app on localhost (foreground). Reads .env. Ctrl-C to stop, or use scripts/stop.sh for the background mode.
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
set -a; [ -f .env ] && . ./.env; set +a
HOST="${LGL_HOST:-127.0.0.1}"; PORT="${LGL_PORT:-8765}"
mkdir -p "${LGL_DATA_DIR:-$HOME/LittleGuyLegal/data}"
if [ "${1:-}" = "--background" ]; then
  nohup python -m uvicorn app.main:app --host "$HOST" --port "$PORT" > "${LGL_DATA_DIR:-$HOME/LittleGuyLegal/data}/uvicorn.out" 2>&1 &
  echo $! > .lgl.pid
  echo "Little Guy Legal started in background (pid $(cat .lgl.pid)) at http://$HOST:$PORT"
else
  echo "Little Guy Legal at http://$HOST:$PORT  (Ctrl-C to stop)"
  exec python -m uvicorn app.main:app --host "$HOST" --port "$PORT"
fi
