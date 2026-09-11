# Stage 3 - Production Deployment (Hostinger / any Ubuntu VPS)

**Goal:** the same stack on a public VPS, behind Traefik with an automatically
renewed Let's Encrypt certificate, with data on persistent volumes and a
rehearsed backup/restore path.

**Milestones covered:** M7 (TLS stack live), M8 (backup/restore drill).

This guide is provider-neutral. Hostinger-specific notes are called out inline.

---

## 3.0 Prerequisites

- Ubuntu 22.04 or 24.04 VPS, 2+ vCPU, 4 GB RAM, 60+ GB disk
  (8 GB RAM / 4 vCPU if you enable the Stage 4 assistant + heavy reporting).
- Root or sudo SSH access.
- A domain you can edit DNS for.
- Open inbound `22`, `80`, `443` in **both** the provider firewall (Hostinger
  hPanel -> VPS -> Firewall) **and** the OS firewall.

---

## 3.1 Server preparation

### a. Automated path

```bash
# On the VPS, as root:
git clone <your-repo-url> solrise-erp && cd solrise-erp
sudo SWAP_SIZE=4G DEPLOY_USER=$SUDO_USER ./scripts/bootstrap-vps.sh
```

The script installs Podman + `podman-compose`, git, ufw, fail2ban, creates the
swap file, writes `/etc/sysctl.d/99-solrise.conf`, opens 22/80/443, sets
subuid/subgid and enables lingering + the podman socket for your deploy user.

### b. What it does, step by step (manual equivalent)

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl git jq ufw fail2ban \
  unattended-upgrades uidmap slirp4netns fuse-overlayfs podman podman-compose
```

```bash
# Swap (2-4 GB): MariaDB and asset compilation both spike memory.
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

```bash
# Kernel tuning required by Redis, Traefik and rootless Podman.
sudo tee /etc/sysctl.d/99-solrise.conf >/dev/null <<'EOF'
net.ipv4.ip_unprivileged_port_start = 80
vm.overcommit_memory = 1
vm.swappiness = 10
net.core.somaxconn = 1024
net.ipv4.tcp_keepalive_time = 600
fs.inotify.max_user_instances = 1024
EOF
sudo sysctl --system
```

```bash
# Rootless Podman for the deploy user.
sudo loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
```

Then, on the deploy user account:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

> **Do not symlink the podman socket to `/var/run/docker.sock`.** Point Traefik
> at the real path instead, via `DOCKER_SOCK` in `.env`
> (`/run/user/<uid>/podman/podman.sock`). That keeps rootless isolation intact.

---

## 3.2 DNS

Create an **A record**:

```
erp.yourdomain.com   A   <VPS public IP>      TTL 300
```

If you use Cloudflare, set the record to **DNS only (grey cloud)** for the first
deployment so Let's Encrypt's HTTP-01 challenge reaches Traefik directly. You can
proxy it afterwards, but then configure the challenge accordingly.

Verify before deploying:

```bash
dig +short erp.yourdomain.com
# must return the VPS IP
```

---

## 3.3 Production `.env`

```bash
cp .env.example .env
```

Set these - the rest can stay default:

```dotenv
COMPOSE_CMD=podman-compose
CONTAINER_ENGINE=podman
DOCKER_SOCK=/run/user/1000/podman/podman.sock    # replace 1000 with `id -u`

SITE_NAME=erp.yourdomain.com
ADMIN_PASSWORD=<strong-and-stored-in-a-password-manager>
DB_ROOT_PASSWORD=<strong>
DB_PASSWORD=<strong>

DOMAIN=erp.yourdomain.com
LETSENCRYPT_EMAIL=you@yourdomain.com

HTTP_PORT=80
HTTPS_PORT=443
```

Confirm the socket path first:

```bash
echo "$XDG_RUNTIME_DIR/podman/podman.sock"
```

> `.env` holds every secret. `chmod 600 .env`, never commit it, and back it up
> somewhere safe - `DB_ROOT_PASSWORD` is what makes your backups restorable.

---

## 3.4 Build and start

```bash
make image                              # bakes erpnext + hrms into the image
SITE_ENV=prod make prod-up              # podman-compose -f compose/compose.prod.yaml up -d
SITE_ENV=prod make ps
SITE_ENV=prod make site                 # create-site (first boot only)
```

All three scripts honour `SITE_ENV=prod` and select `compose/compose.prod.yaml`.

Watch the first TLS issuance:

```bash
SITE_ENV=prod make prod-logs
podman logs --tail=50 <traefik-container>
```

Traefik obtains the certificate on first HTTPS request. Then:

```bash
curl -I https://erp.yourdomain.com
```

You should get `HTTP/2 200` (or a 302 to `/login`) with a valid certificate.

---

## 3.5 How the production topology differs

| Concern | Local | Production |
|---------|-------|------------|
| Entry point | `frontend` on `:8080` | `traefik` on `:80`/`:443` |
| TLS | none | Let's Encrypt via ACME HTTP-01 |
| Frontend exposure | host port | internal only (label-routed) |
| developer_mode | `1` | `0` |
| MariaDB | defaults | `config/mariadb/conf.d/solrise.cnf` |
| Ports | 8080/8443 | 80/443 |

The proxy service is named **`proxy`** (Traefik v3.7) and routes by labels on
the `frontend` service (`compose/compose.prod.yaml`):

```
traefik.http.services.frontend.loadbalancer.server.port=8080
traefik.http.routers.frontend-http.entrypoints=websecure
traefik.http.routers.frontend-http.tls.certresolver=main-resolver
traefik.http.routers.frontend-http.rule=Host(`erp.yourdomain.com`)
```

The `web` entrypoint (port 80) redirects everything to `websecure` (443), and
the `main-resolver` ACME resolver uses the HTTP-01 challenge to issue and renew
the certificate. ACME state lives in the `cert-data` volume - **never delete
it**, or you risk hitting Let's Encrypt's rate limits on re-issue.

---

## 3.6 Persistent volumes

Named volumes are declared in `compose/compose.prod.yaml` and named from `.env`,
so backups and migrations can address them by a stable name:

| Volume | Mount | Contents |
|--------|-------|----------|
| `solrise_sites` | `/home/frappe/frappe-bench/sites` | site config, public+private files, assets, `private/backups` |
| `solrise_db_data` | `/var/lib/mysql` | MariaDB data directory |
| `solrise_redis_queue` | `/data` | durable queue (background jobs) |
| `solrise_letsencrypt` | `/letsencrypt` | ACME account + certificates |

Inspect them:

```bash
podman volume ls | grep solrise
podman volume inspect solrise_sites
```

> The redis **cache** deliberately has no volume - a restart just clears cache.

---

## 3.7 Harden

```bash
# Disable password SSH logins (after you have confirmed key access).
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh

# Automatic security updates.
sudo dpkg-reconfigure --priority=low unattended-upgrades

# Confirm firewall state.
sudo ufw status verbose
```

Operational baseline:

- Rotate the `Administrator` password after first login; create named users and
  assign the Stage 2 roles instead of sharing Administrator.
- Enable **2FA** for Administrator and any `System Manager`
  (**System Settings** -> enable two factor auth).
- Review **Activity Log** / **Error Log** weekly; ship them off-box if you have a
  log aggregator.
- Store `.env` and a copy of the SSL/DB secrets in a password manager.

---

## 3.8 Backup and migration (local -> VPS)

This is the exact sequence for moving your local site to the new VPS. Full
operational detail is in `docs/04-operations-runbook.md`.

### a. Dump on the local machine

```bash
make backup
# -> ./backups/20260912-101500/
#      <stamp>-erp.localhost-database.sql.gz
#      <stamp>-erp.localhost-files.tar
#      <stamp>-erp.localhost-private-files.tar
```

### b. Transfer with SCP

```bash
VPS_USER=root
VPS_HOST=203.0.113.10
STAMP=20260912-101500

scp -r "backups/${STAMP}" "${VPS_USER}@${VPS_HOST}:/root/solrise-backup-${STAMP}"
```

### c. Restore on the VPS

```bash
ssh "${VPS_USER}@${VPS_HOST}"
cd ~/solrise-erp
mkdir -p backups && cp -r /root/solrise-backup-* backups/
SITE_ENV=prod ./scripts/restore.sh "backups/solrise-backup-${STAMP}" --new
```

`--new` creates the empty site first, then restores database + public/private
files into it, then runs `bench migrate` and `clear-cache`.

### d. Verify

```bash
SITE_ENV=prod make ps
podman exec -it solrise-backend bench --site erp.yourdomain.com list-apps
curl -I https://erp.yourdomain.com
```

Log in and spot-check: a CRM lead, an open Issue, an employee record, and a
report. Then delete the copied backup from `/root` on the VPS.

> The site name must match. A dump taken from `erp.localhost` restored into
> `erp.yourdomain.com` is fine - `bench restore` loads data into the target site
> regardless of the source site name. File paths inside the DB that reference
> `/files/...` are relative and remain valid.

---

## 3.9 Ongoing updates

```bash
# Code/config change
git pull
make image
SITE_ENV=prod make prod-up
podman exec -it solrise-backend bench --site erp.yourdomain.com migrate

# Framework/app upgrade (pin the target first, then rebuild)
#   edit CUSTOM_TAG / FRAPPE_BRANCH / apps.json branches in .env
#   make backup            (always before an upgrade)
#   make image
#   SITE_ENV=prod make prod-up
```

---

## Exit criteria

- [ ] `https://erp.yourdomain.com` serves a trusted certificate (no browser warning)
- [ ] `http://` redirects to `https://`
- [ ] All services `Up`; `traefik` healthy
- [ ] Restored data visible after login
- [ ] A fresh `make backup` produces a restorable set
- [ ] SSH password auth disabled; ufw active; 2FA on admin
