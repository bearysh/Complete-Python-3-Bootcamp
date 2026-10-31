#!/usr/bin/env bash
# Back up or restore the case data directory (SQLite DB, originals, extracted text, transcripts, reports).
#   bash scripts/backup_restore.sh backup  [/path/to/backup.tar.gz]
#   bash scripts/backup_restore.sh restore /path/to/backup.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
DATA="${LGL_DATA_DIR:-$HOME/LittleGuyLegal/data}"; DATA="${DATA/#\~/$HOME}"
case "${1:-}" in
  backup) OUT="${2:-$HOME/LittleGuyLegal/backup-$(date +%Y%m%d-%H%M%S).tar.gz}"; mkdir -p "$(dirname "$OUT")"; tar -czf "$OUT" -C "$(dirname "$DATA")" "$(basename "$DATA")"; echo "Backup written to $OUT (keep it on local encrypted storage only)";;
  restore) [ -f "${2:-}" ] || { echo "usage: restore <backup.tar.gz>"; exit 1; }; bash scripts/stop.sh || true; mkdir -p "$(dirname "$DATA")"; tar -xzf "$2" -C "$(dirname "$DATA")"; echo "Restored into $DATA";;
  *) echo "usage: $0 backup [out.tar.gz] | restore <backup.tar.gz>"; exit 1;;
esac
