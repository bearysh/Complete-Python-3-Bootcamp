#!/usr/bin/env bash
# Install Little Guy Legal on the Mac mini (or any machine with Python 3.11+). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
"$PY" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
if [ ! -d .venv ]; then "$PY" -m venv .venv; fi
. .venv/bin/activate
pip install --upgrade pip >/dev/null
pip install -r requirements-dev.txt
[ -f .env ] || { cp .env.example .env; echo "Created .env from .env.example — edit LGL_HERMES_API_KEY and LGL_HERMES_MODEL."; }
python fixtures/synthetic/generate.py >/dev/null
echo "Installed. Next: bash hermes/setup_profile.sh, then bash scripts/start.sh"
