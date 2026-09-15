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

# Only wait for an *embedded* MariaDB. With an external database (RDS) there is
# no mariadb service, and the TCP endpoint is reachable long before the backend
# starts talking to it.
if grep -qE '^  mariadb:' "${COMPOSE_FILE}"; then
  log "waiting for mariadb to report healthy ..."
  # NOTE: `podman-compose ps` takes no service argument, so filter the output.
  for _ in $(seq 1 60); do
    if compose ps 2>/dev/null | grep -i mariadb | grep -qi healthy; then
      break
    fi
    sleep 5
  done
else
  log "external database (no embedded mariadb service) - skipping local db wait"
fi

log "running create-site (idempotent) ..."
compose --profile init run --rm create-site

log "installed apps:"
compose exec -T backend bench --site "${SITE_NAME}" list-apps

# Apply the programmatic configuration. Both scripts are idempotent, so this is
# safe on a brand-new site and on every re-run of `make site`. Order matters:
# roles_rbac.py must run *after* the fixtures sync (done during install-app /
# migrate) so it recreates the shipped-role Custom DocPerm rows it preserves -
# without it, the tight Solrise fixture filter would leave those roles without
# access to the DocTypes it manages. Set SKIP_CONFIG=1 to skip both.
if [ "${SKIP_CONFIG:-0}" = "1" ]; then
  log "SKIP_CONFIG=1 - leaving setup_erp.py / roles_rbac.py to the operator"
else
  log "applying programmatic configuration (idempotent) ..."
  "${SCRIPT_DIR}/run-python.sh" scripts/setup_erp.py
  "${SCRIPT_DIR}/run-python.sh" scripts/roles_rbac.py
fi

log "done. Site: ${SITE_NAME}"
if [ "${SITE_ENV}" = "local" ]; then
  log "open: http://localhost:${HTTP_PORT:-8080}"
else
  log "open: https://${DOMAIN}"
fi
