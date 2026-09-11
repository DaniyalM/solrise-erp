#!/usr/bin/env bash
# Dump database + files from the running site and copy them to the host.
#   ./scripts/backup.sh              # local stack
#   SITE_ENV=prod ./scripts/backup.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

OUT="${BACKUP_DIR:-./backups}"
case "${OUT}" in
  /*) ;;
  *) OUT="${ROOT_DIR}/${OUT#./}" ;;
esac
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${OUT}/${STAMP}"
mkdir -p "${DEST}"

log "dumping ${SITE_NAME} (database + public/private files) ..."
compose exec -T backend bench --site "${SITE_NAME}" backup --with-files

log "streaming dumps out of the sites volume ..."
compose exec -T backend bash -lc \
  "cd /home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups && tar -cf - ." \
  | tar -xf - -C "${DEST}"

log "backup written to ${DEST}"
ls -lh "${DEST}"

log "pruning local backups older than ${BACKUP_RETENTION_DAYS:-14} days ..."
find "${OUT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS:-14}" -exec rm -rf {} + 2>/dev/null || true
log "done"
