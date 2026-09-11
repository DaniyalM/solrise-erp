#!/usr/bin/env bash
# Run a Python file inside the backend container against the live site.
# The script is piped to the bench virtualenv's python; it must be
# self-bootstrapping (see scripts/setup_erp.py for the pattern).
#   ./scripts/run-python.sh scripts/setup_erp.py
#   SITE_ENV=prod ./scripts/run-python.sh scripts/roles_rbac.py
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

FILE="${1:?usage: run-python.sh <python-file>}"
[ -f "${FILE}" ] || die "file not found: ${FILE}"

log "executing ${FILE} against ${SITE_NAME} (${SITE_ENV})"
compose exec -T \
  -e "SITE_NAME=${SITE_NAME}" \
  backend bash -lc \
  'cd /home/frappe/frappe-bench/sites && ../env/bin/python -' < "${FILE}"
log "done"
