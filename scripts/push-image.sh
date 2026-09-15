#!/usr/bin/env bash
# Push the built Solrise image to its registry (ECR when running in CI).
#
#   ./scripts/push-image.sh
#
# Reads CUSTOM_IMAGE / CUSTOM_TAG / CONTAINER_ENGINE from .env, so the same
# command works locally and in GitHub Actions. Authenticate first:
#   aws ecr get-login-password --region "$AWS_REGION" \
#     | podman login --username AWS --password-stdin "${CUSTOM_IMAGE%%/*}"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

: "${CUSTOM_IMAGE:?CUSTOM_IMAGE is not set in .env}"
: "${CUSTOM_TAG:?CUSTOM_TAG is not set in .env}"

REF="${CUSTOM_IMAGE}:${CUSTOM_TAG}"
log "pushing ${REF}"

if "${ENGINE}" push "${REF}"; then
  log "pushed ${REF}"
else
  die "push failed. Is '${CUSTOM_IMAGE%%/*}' the registry and is the tag correct?"
fi
