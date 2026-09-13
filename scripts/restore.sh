#!/usr/bin/env bash
# Restore a backup directory produced by scripts/backup.sh onto the stack.
#
#   ./scripts/restore.sh ./backups/20260912-101500          # into existing site
#   ./scripts/restore.sh ./backups/20260912-101500 --new    # create site first
#
# The site must already exist unless --new is given. --new creates an empty
# site (no apps) and then restores into it, which is the migration path onto a
# fresh VPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

DIR="${1:?usage: restore.sh <backup-dir> [--new]}"
shift || true
NEW_SITE=false
for arg in "$@"; do
  [ "${arg}" = "--new" ] && NEW_SITE=true
done
[ -d "${DIR}" ] || die "backup dir not found: ${DIR}"
DIR="$(cd "${DIR}" && pwd)"

DB_BACKUP="$(find "${DIR}" -maxdepth 1 -name '*-database.sql.gz' | head -n1)"
[ -n "${DB_BACKUP}" ] || die "no *-database.sql.gz found in ${DIR}"
PUB_BACKUP="$(find "${DIR}" -maxdepth 1 -name '*-files.tar' ! -name '*private*' | head -n1 || true)"
PRIV_BACKUP="$(find "${DIR}" -maxdepth 1 -name '*-private-files.tar' | head -n1 || true)"

log "backup dir : ${DIR}"
log "database   : $(basename "${DB_BACKUP}")"
log "public     : ${PUB_BACKUP:+$(basename "${PUB_BACKUP}")}"

if [ "${NEW_SITE}" = true ]; then
  log "creating empty site ${SITE_NAME} before restore ..."
  compose --profile init run --rm create-site
fi

REL="/tmp/solrise-restore"
log "copying backup into the backend container ..."
compose exec -T backend bash -lc "rm -rf ${REL} && mkdir -p ${REL}"
tar -cf - -C "${DIR}" . | compose exec -T backend bash -lc "tar -xf - -C ${REL}"

# bench restore needs the DB root password; without it, it prompts on stdin and
# silently aborts a non-interactive restore (see docs/09 execution log).
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is not set in .env - bench restore needs it}"
RESTORE_ARGS=("bench" "--site" "${SITE_NAME}" "--force" "restore" "${REL}/$(basename "${DB_BACKUP}")")
RESTORE_ARGS+=("--mariadb-root-username" "${DB_ROOT_USERNAME:-root}")
RESTORE_ARGS+=("--mariadb-root-password" "${DB_ROOT_PASSWORD}")
[ -n "${ADMIN_PASSWORD:-}" ] && RESTORE_ARGS+=("--admin-password" "${ADMIN_PASSWORD}")
[ -n "${PUB_BACKUP}" ] && RESTORE_ARGS+=("--with-public-files" "${REL}/$(basename "${PUB_BACKUP}")")
[ -n "${PRIV_BACKUP}" ] && RESTORE_ARGS+=("--with-private-files" "${REL}/$(basename "${PRIV_BACKUP}")")

log "running bench restore ..."
compose exec -T backend "${RESTORE_ARGS[@]}"

log "migrating + clearing cache ..."
compose exec -T backend bench --site "${SITE_NAME}" migrate
compose exec -T backend bench --site "${SITE_NAME}" clear-cache

log "restore complete. Verify at https://${DOMAIN:-localhost}"
