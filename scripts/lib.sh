#!/usr/bin/env bash
# Shared helpers for Solrise ERP scripts. Source this, do not execute it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

# Load .env (portable across CachyOS Podman and any VPS).
if [ -f "${ROOT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${ROOT_DIR}/.env"
  set +a
else
  echo "ERROR: .env not found. Run: cp .env.example .env" >&2
  exit 1
fi

: "${SITE_NAME:?SITE_NAME is not set in .env}"
: "${COMPOSE_PROJECT_NAME:=solrise}"

ENGINE="${CONTAINER_ENGINE:-podman}"
COMPOSE_CMD="${COMPOSE_CMD:-podman-compose}"
# Which stack to target: local (default) or prod.
SITE_ENV="${SITE_ENV:-local}"

case "${SITE_ENV}" in
  local) COMPOSE_FILE="${ROOT_DIR}/compose/compose.local.yaml" ;;
  prod)  COMPOSE_FILE="${ROOT_DIR}/compose/compose.prod.yaml" ;;
  # AWS: same topology as prod, but MariaDB lives on RDS instead of in a
  # container. See compose/compose.aws.yaml and infra/.
  aws)   COMPOSE_FILE="${ROOT_DIR}/compose/compose.aws.yaml" ;;
  *) echo "ERROR: SITE_ENV must be 'local', 'prod' or 'aws' (got '${SITE_ENV}')" >&2; exit 1 ;;
esac

# Optional extra compose files, layered after the primary one (space separated).
# Used to rehearse the production topology on a workstation, where public ACME
# cannot run:
#   SITE_ENV=prod COMPOSE_EXTRA_FILES=compose/compose.prod.test.yaml \
#     ./scripts/create-site.sh
COMPOSE_EXTRA_FILES="${COMPOSE_EXTRA_FILES:-}"

compose() {
  local files=(-f "${COMPOSE_FILE}")
  local extra
  for extra in ${COMPOSE_EXTRA_FILES}; do
    [ -f "${ROOT_DIR}/${extra}" ] || die "COMPOSE_EXTRA_FILES: not found: ${extra}"
    files+=(-f "${ROOT_DIR}/${extra}")
  done
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} "${files[@]}" --env-file "${ROOT_DIR}/.env" "$@"
}

log() { printf '\033[36m[solrise]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[solrise:error]\033[0m %s\n' "$*" >&2; exit 1; }
