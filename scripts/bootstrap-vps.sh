#!/usr/bin/env bash
# =============================================================================
# Solrise ERP - one-shot preparation of a fresh Ubuntu VPS (22.04 / 24.04).
#
# Run ON THE VPS as root (or with sudo):
#     sudo SWAP_SIZE=4G DEPLOY_USER=$USER ./scripts/bootstrap-vps.sh
#
# Idempotent: safe to re-run. Installs Podman, git, firewall, swap and the
# sysctl values MariaDB/Redis/Traefik need. Nothing here is vendor-specific,
# so it works on Hostinger, Hetzner, DigitalOcean, etc.
# =============================================================================
set -euo pipefail

SWAP_SIZE="${SWAP_SIZE:-4G}"
DEPLOY_USER="${DEPLOY_USER:-${SUDO_USER:-$(id -un)}}"
UNPRIV_PORT_START="${UNPRIV_PORT_START:-80}"

log() { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[bootstrap:error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./scripts/bootstrap-vps.sh"
id "${DEPLOY_USER}" >/dev/null 2>&1 || die "deploy user '${DEPLOY_USER}' does not exist"

# --- 1. Base packages --------------------------------------------------------
log "updating apt and installing base packages ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  ca-certificates curl gnupg git jq ufw fail2ban unattended-upgrades \
  uidmap slirp4netns fuse-overlayfs podman podman-compose

# --- 2. Swap file ------------------------------------------------------------
if [ ! -f /swapfile ]; then
  log "creating ${SWAP_SIZE} swapfile ..."
  fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  log "swapfile already present, skipping"
fi

# --- 3. Kernel tuning --------------------------------------------------------
log "writing /etc/sysctl.d/99-solrise.conf ..."
cat > /etc/sysctl.d/99-solrise.conf <<SYSCTL
# Allow rootless Podman to bind 80/443 (Traefik) without CAP_NET_BIND_SERVICE.
net.ipv4.ip_unprivileged_port_start = ${UNPRIV_PORT_START}
# Redis background save fork() can be refused without this.
vm.overcommit_memory = 1
vm.swappiness = 10
net.core.somaxconn = 1024
net.ipv4.tcp_keepalive_time = 600
fs.inotify.max_user_instances = 1024
SYSCTL
sysctl --system >/dev/null

# --- 4. Firewall -------------------------------------------------------------
log "configuring ufw (ssh, 80, 443) ..."
ufw allow OpenSSH >/dev/null || true
ufw allow 80/tcp  >/dev/null || true
ufw allow 443/tcp >/dev/null || true
ufw --force enable >/dev/null || true

# --- 5. Rootless Podman for the deploy user ----------------------------------
log "enabling persistent user session + podman socket for ${DEPLOY_USER} ..."
loginctl enable-linger "${DEPLOY_USER}" 2>/dev/null || true
if command -v sudo >/dev/null 2>&1; then
  sudo -u "${DEPLOY_USER}" XDG_RUNTIME_DIR="/run/user/$(id -u "${DEPLOY_USER}")" \
    systemctl --user enable --now podman.socket 2>/dev/null || \
    log "WARN: could not start podman.socket for ${DEPLOY_USER}; do it after first login"
fi

# --- 6. Subordinate UID/GID ranges (needed for rootless volume ownership) ----
USUB="$(id -u "${DEPLOY_USER}")"
if ! grep -q "^${DEPLOY_USER}:" /etc/subuid 2>/dev/null; then
  log "adding subuid/subgid ranges for ${DEPLOY_USER} ..."
  usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${DEPLOY_USER}"
else
  log "subuid/subgid already configured for ${DEPLOY_USER}"
fi

log "bootstrap complete."
log "next: log in as ${DEPLOY_USER}, clone the repo, cp .env.example .env, edit it,"
log "      then: make image && SITE_ENV=prod make prod-up && SITE_ENV=prod make site"
