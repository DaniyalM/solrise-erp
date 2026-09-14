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

### e. Local rehearsal (verified)

The dump -> restore half of this path is rehearsed locally:

```bash
make backup                              # ./backups/<stamp>/
./scripts/restore.sh ./backups/<stamp>   # same site, bench restore --force
```

Verified 2026-09-13: `make backup` produced a complete set (database, public and
private files, site config); `restore.sh` reloaded it, re-ran migrate and
clear-cache, and the post-restore fingerprint matched exactly - 6 roles,
4 workflows, 9 reports, 368 `Custom DocPerm` rows, the `Solrise AI Audit Log`
DocType, and `enable_universal_chat = 1`.

> **Bug found and fixed here.** `bench restore` needs the DB root password. The
> script did not pass it, so a non-interactive restore stopped at an interactive
> `MySQL root password:` prompt and silently did nothing. `restore.sh` now passes
> `--mariadb-root-username` / `--mariadb-root-password` (and `--admin-password`
> for `--new`) from `.env`, and fails fast with a clear message when
> `DB_ROOT_PASSWORD` is unset. This is why `DB_ROOT_PASSWORD` is the one secret
> your backups depend on.

The SCP hop and the restore onto a real VPS still need a host (see M7).

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

## 3.10 Rehearsing the production stack on a workstation

You can bring the *production* topology up on a workstation before touching a
VPS, to catch compose/config problems early. Public ACME cannot work here (the
HTTP-01 challenge needs a public domain pointed at this machine), so the only
thing you cannot rehearse is certificate issuance.

```bash
make local-down                     # local and prod share volumes - never both

# .env: DOMAIN and SITE_NAME must match, and DOCKER_SOCK must be the podman socket
#   DOMAIN=erp.localhost            SITE_NAME=erp.localhost
#   DOCKER_SOCK=/run/user/$(id -u)/podman/podman.sock
#   TLS_CERT_RESOLVER=              (empty -> Traefik's built-in self-signed cert)

SITE_ENV=prod ./scripts/create-site.sh     # up + create-site + config + RBAC

curl -sk --resolve erp.localhost:8443:127.0.0.1 \
     -o /dev/null -w "login %{http_code}\n" https://erp.localhost:8443/login
```

On the VPS, remove `TLS_CERT_RESOLVER` from `.env` so the `main-resolver` issues
the real certificate.

### What this rehearsal proves

Verified on 2026-09-14 against the production compose file: all ten services up,
`proxy` healthy, HTTP `:8080` redirects to HTTPS, HTTPS terminates through
traefik to the frontend, `/login` `200`, app assets `200`, `/api/method/ping`
`200`, the `solrise-compress` middleware active (`Content-Encoding: gzip`),
create-site idempotent, `bench migrate` clean with `developer_mode 0`, the prod
backup path works, scheduled tasks run, and the site survives a full
`down`/`up` (named volumes persist).

### Not provable locally

Let's Encrypt issuance and renewal, and the `http -> https` redirect landing on
the real domain (locally the redirect targets `:443`, which is published as
`8443`). Both are VPS-only, and both are pure Traefik configuration - the code
and data path they front were exercised above.

### Issues this rehearsal found (fixed)

| Issue | Fix |
|---|---|
| `proxy` always reported **unhealthy**: the healthcheck ran `traefik healthcheck`, which needs `--ping` and cannot see the server's flags from a fresh process. | `--ping=true` + `--entrypoints.traefik.address=:8080`, and the healthcheck now probes `http://127.0.0.1:8080/ping` directly. |
| `config/traefik/dynamic.yaml` was **never mounted**, so its middleware, transport timeouts and TLS options silently did nothing. | The `proxy` service mounts it and passes `--providers.file.directory`; the router now uses `solrise-compress@file` and `solrise-upstream@file`. |
| `sniStrict: true` in that file broke every handshake whose SNI did not match a served certificate (self-signed rehearsals, IP-based probes) - and Traefik applies the option named `default` **globally**. | Removed `sniStrict`; `minVersion: VersionTLS12` and the cipher suites remain. |
| `.env` shipped `DOCKER_SOCK=/var/run/docker.sock` and `DOMAIN` that disagreed with `SITE_NAME`, so Traefik could not reach podman and no router matched. | Documented the required values above. |
| A site created by the **local** stack keeps `developer_mode = 1` at site level, which overrides the prod global. | On the VPS, `create-site` sets it to `0`; when rehearsing on existing data run `bench --site <site> set-config developer_mode 0`. |

> Local and production compose files declare the **same named volumes**
> (`solrise_sites`, `solrise_db_data`, `solrise_redis_queue`), so the rehearsal
> reuses your local site - which is exactly what a restore onto a VPS looks like.
> It also means you must stop one stack before starting the other.

---

## Exit criteria

- [ ] `https://erp.yourdomain.com` serves a trusted certificate (no browser warning)
- [ ] `http://` redirects to `https://`
- [ ] All services `Up`; `traefik` healthy
- [ ] Restored data visible after login
- [x] A fresh `make backup` produces a restorable set (verified locally, §3.8e)
- [ ] SSH password auth disabled; ufw active; 2FA on admin

> Locally verifiable parts are done: `bootstrap-vps.sh` passes `bash -n`, the
> production compose file renders with its Traefik labels, and the
> backup -> restore round trip is rehearsed. The TLS and off-host steps need a
> VPS with a domain pointed at it.
