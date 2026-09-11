#!/usr/bin/env bash
# Export Custom Field / Property Setter / Workflow / Role / Custom DocPerm etc.
# into ./fixtures so they re-apply automatically on any new deployment
# (via the `fixtures` list in the Solrise app's hooks.py).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

mkdir -p "${ROOT_DIR}/fixtures"
log "exporting fixtures from ${SITE_NAME} ..."
compose exec -T backend bench --site "${SITE_NAME}" export-fixtures
log "fixtures exported inside the container"
