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
  *) echo "ERROR: SITE_ENV must be 'local' or 'prod' (got '${SITE_ENV}')" >&2; exit 1 ;;
esac

compose() {
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ROOT_DIR}/.env" "$@"
}

log() { printf '\033[36m[solrise]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[solrise:error]\033[0m %s\n' "$*" >&2; exit 1; }
