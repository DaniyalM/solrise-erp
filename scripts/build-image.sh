#!/usr/bin/env bash
# Build the Solrise image: Frappe + the platform + HRMS baked in from apps.json.
#
# frappe_docker's *layered* Containerfile installs the apps listed in apps.json,
# passed as a BuildKit SECRET (never a build arg) so private-repo tokens cannot
# leak into image layer metadata.
#
# FRAPPE_BRANCH selects both the frappe/base and frappe/build base images AND the
# branch `bench init` checks out, so the toolchain (python/node) always matches
# the framework. Keep FRAPPE_BRANCH and the apps.json branches on the same major.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

[ -f .env ] || { echo "ERROR: .env not found (cp .env.example .env)" >&2; exit 1; }
set -a; . ./.env; set +a

: "${CUSTOM_IMAGE:?CUSTOM_IMAGE is not set}"
: "${CUSTOM_TAG:?CUSTOM_TAG is not set}"
: "${FRAPPE_PATH:?FRAPPE_PATH is not set}"
: "${FRAPPE_BRANCH:?FRAPPE_BRANCH is not set}"

ENGINE="${CONTAINER_ENGINE:-podman}"
FD_DIR="${FRAPPE_DOCKER_DIR:-./frappe_docker}"
case "${FD_DIR}" in
  /*) ;;
  *) FD_DIR="${ROOT_DIR}/${FD_DIR#./}" ;;
esac

if [ ! -f "${FD_DIR}/images/layered/Containerfile" ]; then
  echo "[solrise] cloning frappe_docker into ${FD_DIR}"
  git clone --depth 1 https://github.com/frappe/frappe_docker "${FD_DIR}"
fi

# The app list comes from apps.json on disk, never inline in .env: a
# shell-sourced variable has its JSON quotes stripped by brace expansion.
# "${VAR}" references inside apps.json ARE expanded from the environment, so the
# same apps.json works on any host (local git daemon, GitHub, GitLab...).
APPS_SRC="${APPS_JSON_FILE:-$ROOT_DIR/apps.json}"
case "${APPS_SRC}" in
  /*) ;;
  *) APPS_SRC="${ROOT_DIR}/${APPS_SRC#./}" ;;
esac
[ -f "${APPS_SRC}" ] || { echo "ERROR: app list not found: ${APPS_SRC}" >&2; exit 1; }

# The Containerfile reads the secret from the build context (frappe_docker root).
APPS_FILE="${FD_DIR}/apps.json"
python3 - "${APPS_SRC}" "${APPS_FILE}" <<'PY' || exit 1
import json, os, re, sys

src, dest = sys.argv[1], sys.argv[2]
raw = open(src).read()


def expand(match):
    name = match.group(1)
    value = os.environ.get(name)
    if not value:
        sys.stderr.write(
            "ERROR: %s references ${%s} but it is not set in .env\n" % (src, name))
        sys.exit(1)
    return value


resolved = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", expand, raw)
try:
    apps = json.loads(resolved)
except ValueError as exc:
    sys.stderr.write("ERROR: invalid JSON after substitution: %s\n" % exc)
    sys.exit(1)

with open(dest, "w") as handle:
    json.dump(apps, handle, indent=2)

print("[solrise] apps baked into the image:")
for app in apps:
    print("  - %s @ %s" % (app.get("url"), app.get("branch")))
PY

# The apps.json secret is NOT part of the build cache key, so a changed app list
# OR a moved app branch would otherwise reuse a cached `bench init` and silently
# ship a stale image. The Containerfile exposes ARG CACHE_BUST for this; the
# fingerprint covers the app list plus each git app's remote commit. Set
# SOLRISE_APP_REV in .env to force a refresh (e.g. an unreachable private remote).
CACHE_BUST_VALUE="$(python3 "${ROOT_DIR}/scripts/apps-fingerprint.py" "${APPS_FILE}")"
echo "[solrise] cache-bust=${CACHE_BUST_VALUE:0:12}"

echo "[solrise] building ${CUSTOM_IMAGE}:${CUSTOM_TAG} (FRAPPE_BRANCH=${FRAPPE_BRANCH})"
# Podman resolves `--secret src=` relative to the CURRENT WORKING DIRECTORY, not
# the build context. Building from the repo root (which also contains an
# apps.json) silently bakes the WRONG app list, so build from inside the context.
cd "${FD_DIR}"
"${ENGINE}" build \
  --build-arg "FRAPPE_PATH=${FRAPPE_PATH}" \
  --build-arg "FRAPPE_BRANCH=${FRAPPE_BRANCH}" \
  --build-arg "FRAPPE_IMAGE_PREFIX=${FRAPPE_IMAGE_PREFIX:-docker.io/frappe}" \
  --build-arg "CACHE_BUST=${CACHE_BUST:-${CACHE_BUST_VALUE}}" \
  --secret "id=apps_json,src=apps.json" \
  --tag "${CUSTOM_IMAGE}:${CUSTOM_TAG}" \
  --file "images/layered/Containerfile" \
  "${FD_DIR}"

echo "[solrise] built ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
"${ENGINE}" images | grep -F "${CUSTOM_IMAGE}" || true
