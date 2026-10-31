#!/usr/bin/env bash
# Create and configure the dedicated Hermes profile "little-guy-legal" on the Mac mini.
# - Never touches the personal default profile or any other profile.
# - Creates an EMPTY profile (no cloned config, memory, sessions, skills, or credentials).
# - Writes config.yaml from hermes/little-guy-legal.config.yaml and a .env with a fresh random API key.
# Usage: bash hermes/setup_profile.sh [OMLX_BASE_URL] [OMLX_MODEL_ID]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE=little-guy-legal
HERMES_ROOT="${HERMES_HOME_ROOT:-$HOME/.hermes}"
PROFILE_DIR="$HERMES_ROOT/profiles/$PROFILE"
OMLX_URL="${1:-}"
OMLX_MODEL="${2:-}"

command -v hermes >/dev/null || { echo "hermes CLI not found on PATH"; exit 1; }
echo "Hermes version: $(hermes version 2>/dev/null | head -1 || echo unknown)"

if [ -d "$PROFILE_DIR" ]; then
  echo "Profile directory already exists: $PROFILE_DIR (leaving existing files; config.yaml will be refreshed)"
else
  # --no-skills: do not seed bundled skills. No --clone flags: nothing is copied from the default profile.
  hermes profile create "$PROFILE" --no-skills --no-alias --description "Little Guy Legal isolated inference profile"
fi

# Discover OMLX if not provided
if [ -z "$OMLX_URL" ]; then
  for port in 8000 8080 1234 11434; do
    if curl -s -m 2 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then OMLX_URL="http://127.0.0.1:$port/v1"; break; fi
  done
fi
[ -n "$OMLX_URL" ] || { echo "Could not find an OpenAI-compatible server on loopback; pass the OMLX base URL as the first argument."; exit 1; }
case "$OMLX_URL" in http://127.0.0.1*|http://localhost*) ;; *) echo "Refusing non-loopback endpoint: $OMLX_URL"; exit 1;; esac
if [ -z "$OMLX_MODEL" ]; then
  OMLX_MODEL="$(curl -s -m 5 "${OMLX_URL%/}/models" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"][0]["id"])' 2>/dev/null || true)"
fi
[ -n "$OMLX_MODEL" ] || { echo "Could not determine a model id from $OMLX_URL/models; pass it as the second argument."; exit 1; }
echo "Using OMLX endpoint $OMLX_URL with model $OMLX_MODEL"

sed -e "s#http://127.0.0.1:8000/v1#${OMLX_URL%/}#g" -e "s#REPLACE_WITH_EXACT_OMLX_MODEL_ID#${OMLX_MODEL}#g" \
  "$HERE/little-guy-legal.config.yaml" > "$PROFILE_DIR/config.yaml"

if [ ! -f "$PROFILE_DIR/.env" ] || ! grep -q '^API_SERVER_KEY=.\{16,\}' "$PROFILE_DIR/.env"; then
  KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  umask 077
  printf 'API_SERVER_KEY=%s\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT=8642\nAPI_SERVER_MODEL_NAME=little-guy-legal\n' "$KEY" > "$PROFILE_DIR/.env"
  chmod 600 "$PROFILE_DIR/.env"
  echo "Wrote new API key to $PROFILE_DIR/.env (not printed). Copy it into the app's .env as LGL_HERMES_API_KEY:"
  echo "  grep API_SERVER_KEY $PROFILE_DIR/.env | sed 's/API_SERVER_KEY/LGL_HERMES_API_KEY/' >> .env"
fi
# Marker that prevents bundled-skill seeding on future `hermes update`
touch "$PROFILE_DIR/.no-bundled-skills"
echo
echo "Profile ready: $PROFILE_DIR"
echo "Start the isolated API server with:   hermes -p $PROFILE gateway run"
echo "Then verify the effective configuration: python hermes/verify_profile.py"
