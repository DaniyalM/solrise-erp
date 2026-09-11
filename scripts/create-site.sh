#!/usr/bin/env bash
# Bring the stack up, then create the site and install apps (idempotent).
#   SITE_ENV=local ./scripts/create-site.sh
#   SITE_ENV=prod  ./scripts/create-site.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

log "stack: ${SITE_ENV} (${COMPOSE_FILE})"
log "starting services ..."
compose up -d

log "waiting for mariadb to report healthy ..."
# NOTE: `podman-compose ps` takes no service argument, so filter the output.
for _ in $(seq 1 60); do
  if compose ps 2>/dev/null | grep -i mariadb | grep -qi healthy; then
    break
  fi
  sleep 5
done

log "running create-site (idempotent) ..."
compose --profile init run --rm create-site

log "installed apps:"
compose exec -T backend bench --site "${SITE_NAME}" list-apps

log "done. Site: ${SITE_NAME}"
if [ "${SITE_ENV}" = "local" ]; then
  log "open: http://localhost:${HTTP_PORT:-8080}"
else
  log "open: https://${DOMAIN}"
fi
