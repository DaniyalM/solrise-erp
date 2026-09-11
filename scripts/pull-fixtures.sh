#!/usr/bin/env bash
# Pull exported fixtures out of the container and into ./fixtures/<app>/fixtures.
# NOTE: app sources live in the image, not in a volume, so anything exported
# here is lost when the image is rebuilt. Commit the results to your app repo
# (see docs/02-phase2-module-config.md) to make them durable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

DEST="${ROOT_DIR}/fixtures"
mkdir -p "${DEST}"
log "pulling fixtures from the backend container ..."
compose exec -T backend bash -lc \
  'cd /home/frappe/frappe-bench/apps && tar -cf - --exclude="*/node_modules" */fixtures 2>/dev/null' \
  | tar -xf - -C "${DEST}"
log "fixtures pulled into ${DEST}"
find "${DEST}" -name '*.json' | sort
