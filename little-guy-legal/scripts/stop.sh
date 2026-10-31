#!/usr/bin/env bash
# Stop a background instance started with scripts/start.sh --background. Case data is untouched.
cd "$(dirname "$0")/.."
if [ -f .lgl.pid ]; then kill "$(cat .lgl.pid)" 2>/dev/null && echo "Stopped pid $(cat .lgl.pid)"; rm -f .lgl.pid; else echo "No .lgl.pid file; nothing to stop."; fi
