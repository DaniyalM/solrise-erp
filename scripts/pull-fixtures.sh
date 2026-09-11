#!/usr/bin/env bash
# Pull exported fixtures out of the container and into ./fixtures/<app>/fixtures.
#
# `bench export-fixtures` writes to apps/<app>/<module>/fixtures (the module
# folder is usually named after the app), NOT apps/<app>/fixtures, so a bare
# */fixtures glob matches nothing. This script resolves either layout, copies
# only the apps we ask for (framework and test fixtures must never be committed
# here), and lands them in the documented ./fixtures/<app>/fixtures layout.
#
# NOTE: app sources live in the image, not in a volume, so anything exported
# here is lost when the image is rebuilt. Commit the results to your app repo
# (see docs/02-phase2-module-config.md) to make them durable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

DEST="${ROOT_DIR}/fixtures"
# Default to the custom app only. Override for more, e.g.
#   FIXTURE_APPS="solrise_erp another_app" ./scripts/pull-fixtures.sh
FIXTURE_APPS="${FIXTURE_APPS:-solrise_erp}"
mkdir -p "${DEST}"

log "pulling fixtures for [${FIXTURE_APPS}] from the backend container ..."
compose exec -T -e "FIXTURE_APPS=${FIXTURE_APPS}" backend bash -lc '
  set -euo pipefail
  cd /home/frappe/frappe-bench/apps
  stage="$(mktemp -d)"
  trap "rm -rf $stage" EXIT
  found=0
  for app in $FIXTURE_APPS; do
    for fdir in "$app/$app/fixtures" "$app/fixtures"; do
      if [ -d "$fdir" ]; then
        mkdir -p "$stage/$app/fixtures"
        cp -a "$fdir/." "$stage/$app/fixtures/"
        echo "  $fdir" >&2
        found=1
        break
      fi
    done
  done
  if [ "$found" -ne 1 ]; then
    echo "no fixtures found for: $FIXTURE_APPS" >&2
    exit 1
  fi
  tar -C "$stage" -cf - .
' | tar -xf - -C "${DEST}"
log "fixtures pulled into ${DEST}"
find "${DEST}" -name '*.json' | sort
