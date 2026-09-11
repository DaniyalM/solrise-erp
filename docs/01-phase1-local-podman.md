# Stage 1 - Local Setup with rootless Podman

**Goal:** a working Solrise ERP + HRMS site on `http://localhost:8080`, built from
the same image and compose topology that production uses.

**Milestones covered:** M1 (image builds), M2 (stack healthy), M3 (site live).

---

## 0. Prerequisites

| Requirement | Check |
|-------------|-------|
| Podman >= 4.7 | `podman --version` |
| podman-compose | `podman-compose --version` (or use `podman compose`) |
| git, make, curl | `git --version && make --version` |
| ~8 GB free disk, 4 GB RAM | `df -h . && free -h` |

Install on Arch/CachyOS:

```bash
sudo pacman -S --needed podman podman-compose git make curl
```

---

## 1.1 Repository and project directory

```bash
git clone <your-repo-url> solrise-erp
cd solrise-erp
cp .env.example .env
chmod +x scripts/*.sh
```

`scripts/build-image.sh` clones `frappe_docker` into `./frappe_docker`
(git-ignored) on first use, so you do not need a separate checkout.

> If you already have `frappe_docker` elsewhere, point `FRAPPE_DOCKER_DIR` at it
> in `.env` (absolute path recommended).

---

## 1.2 Rootless Podman: subuid / subgid and volume permissions

Rootless Podman maps container UIDs into a subordinate range on the host. The
Frappe images run as UID/GID **1000** (`frappe`), so clean volume mounts depend
on that mapping being present and generous enough.

**a. Verify the ranges exist**

```bash
grep "^$USER:" /etc/subuid /etc/subgid
```

Expected, at minimum:

```
/etc/subuid:daniyalm:100000:65536
/etc/subgid:daniyalm:100000:65536
```

**b. Add them if missing** (then re-map the storage):

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate        # re-applies mappings to existing containers
```

> `podman system migrate` recreates the user namespace for existing containers.
> If a container misbehaves afterwards, `podman rm -f` it and recreate.

**c. Allow unprivileged binding of low ports** (needed for Traefik on 80/443
in production, harmless here):

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
echo 'net.ipv4.ip_unprivileged_port_start=80' | \
  sudo tee /etc/sysctl.d/99-solrise.conf
```

**d. Volume ownership rules that avoid the classic "permission denied"**

- Prefer **named volumes** (what this repo uses). Podman maps ownership
  automatically, so the container's UID 1000 can write without any host chown.
- If you switch to a **bind mount** (e.g. `- ./sites:/home/frappe/frappe-bench/sites`),
  add the `:U` flag so Podman chowns it to the mapped UID:

  ```yaml
  volumes:
    - ./sites:/home/frappe/frappe-bench/sites:U
  ```

  The `:U` flag recursively changes ownership of the host path - never point it
  at a directory you do not exclusively own.
- On SELinux hosts add `:Z` (or `:z`) to bind mounts for relabelling.

**e. Keep the stack alive after logout:**

```bash
loginctl enable-linger "$USER"
```

---

## 1.3 Podman API socket (optional locally, required for Traefik on the VPS)

```bash
systemctl --user enable --now podman.socket
systemctl --user status podman.socket --no-pager
ls -l "${XDG_RUNTIME_DIR}/podman/podman.sock"
```

If you plan to test the production compose locally, set in `.env`:

```
DOCKER_SOCK=${XDG_RUNTIME_DIR}/podman/podman.sock
```

---

## 1.4 Configure `.env`

Open `.env` and set at minimum:

```dotenv
SITE_NAME=erp.localhost
ADMIN_PASSWORD=<a-strong-password>
DB_ROOT_PASSWORD=<a-strong-password>
DB_PASSWORD=<a-strong-password>
HTTP_PORT=8080
COMPOSE_CMD=podman-compose
CONTAINER_ENGINE=podman
```

Everything else can stay at its default. `.env` is the only file that changes
between local and production - see `docs/03-phase3-production-vps.md`.

> **`.env` is shell-sourced, so keep values shell-safe.** No unquoted spaces and
> no inline JSON: `INSTALL_APPS=erpnext hrms` makes bash try to run `hrms`, and
> `APPS_JSON=[{...}]` loses its quotes to brace expansion and becomes invalid
> JSON - silently. That is why the app list lives in `apps.json` and
> `INSTALL_APPS` is comma-separated. Both bugs were hit for real.

**Hostname resolution:** most systems resolve `*.localhost` to `127.0.0.1`
automatically. If `ping erp.localhost` fails, add:

```bash
echo '127.0.0.1 erp.localhost' | sudo tee -a /etc/hosts
```

---

## 1.5 Build the custom image (M1)

The stock `frappe/erpnext` image does not contain HRMS, and `bench get-app`
inside a running container is erased on the next `up`. So the apps are baked in
from `apps.json` at build time.

```bash
make image          # -> ./scripts/build-image.sh
```

What it does:
1. clones `frappe_docker` into `./frappe_docker` if absent,
2. copies `apps.json` into the build context,
3. builds `solrise/erpnext:version-15` from `images/layered/Containerfile`,
   passing the app list as the BuildKit secret `apps_json`.

> **Verified behaviour (see `docs/09-execution-log.md`).** Current `frappe_docker`
> consumes `apps.json` as a BuildKit **secret**, not as a build argument - do not
> pass `APPS_JSON_BASE64`. It also expects `FRAPPE_IMAGE_PREFIX` to be fully
> qualified (`docker.io/frappe`); rootless Podman will not resolve the short name.
> `FRAPPE_BRANCH` selects the `frappe/base` + `frappe/build` images *and* the
> branch, so the toolchain matches the framework (v15 -> CPython 3.11).

Verify:

```bash
podman images | grep solrise
```

> First build takes 10-25 minutes (it compiles the Frappe assets). Subsequent
> builds reuse layers and take about a minute.

---

## 1.6 Start the stack (M2)

```bash
make local-up      # podman-compose -f compose/compose.local.yaml --env-file .env up -d
make ps
```

Services you should see `Up`:

| Service | Role |
|---------|------|
| `mariadb` | database (healthcheck-gated) |
| `redis-cache` | cache + socketio pub/sub |
| `redis-queue` | background job queue (persistent) |
| `configurator` | one-shot: writes `common_site_config.json` |
| `backend` | gunicorn / `bench serve` |
| `websocket` | socketio for realtime updates |
| `queue-short` / `queue-long` | background workers |
| `scheduler` | scheduled jobs (reminders, SLA checks) |
| `frontend` | nginx, publishes `${HTTP_PORT}` |

`configurator` is expected to show as **Exited (0)** - that is success.

Follow startup:

```bash
make logs
```

---

## 1.7 Initialize the site (M3)

```bash
make site          # -> ./scripts/create-site.sh
```

Equivalent raw command (this is what the script runs):

```bash
podman-compose -f compose/compose.local.yaml --env-file .env \
  --profile init run --rm create-site
```

Inside the container that one-shot performs:

```bash
bench new-site --mariadb-root-password "$DB_ROOT_PASSWORD" \
               --admin-password "$ADMIN_PASSWORD" \
               --no-mariadb-socket "$SITE_NAME"
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" enable-scheduler
bench use "$SITE_NAME"
```

The service is **idempotent**: if `sites/$SITE_NAME` already exists it prints a
skip and exits. Re-running `make site` on a live site is safe.

---

## 1.8 Verify

```bash
# 1. Containers
make ps

# 2. Apps actually installed inside the site
podman exec -it solrise-backend bench --site erp.localhost list-apps

# 3. HTTP reachable
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080

# 4. Scheduler is ticking
podman logs --tail=30 solrise-scheduler

# 5. Workers are consuming
podman logs --tail=30 solrise-queue-short
```

Then open **http://localhost:8080** and log in:

- **Username:** `Administrator`
- **Password:** the `ADMIN_PASSWORD` from `.env`

Expected apps in step 2:

```
frappe
erpnext
hrms
```

> Container names differ by engine: `podman-compose` uses **underscores**
> (`solrise_backend_1`), Docker Compose uses **hyphens** (`solrise-backend-1`).
> The docs below use the friendly form `solrise-backend`; list the real names with
> `podman ps --format '{{.Names}}'`.

---

## 1.9 Everyday commands

```bash
make logs        # tail everything
make ps          # status
make shell       # bash inside the backend container
make backup      # dump DB + files to ./backups
make local-down  # stop (keeps volumes)
```

To wipe and start over (destroys all data):

```bash
podman-compose -f compose/compose.local.yaml --env-file .env down -v
make image local-up site
```

---

## 1.10 Choosing a compose runner

Both of these work; pick one and stay consistent:

```bash
# A. podman-compose (Python, most portable)
podman-compose -f compose/compose.local.yaml --env-file .env up -d

# B. podman's built-in compose provider (Podman >= 4.7, needs docker-compose binary)
podman compose -f compose/compose.local.yaml --env-file .env up -d
```

Set `COMPOSE_CMD` in `.env` to whichever you use so the scripts and Makefile
follow along:

```dotenv
COMPOSE_CMD=podman-compose      # or: podman compose
```

> `podman-compose` has partial support for `depends_on: condition:
> service_completed_successfully`. If the backend starts before the configurator
> finishes, restart it once (`podman-compose restart backend`) or re-run
> `make local-up`. See `docs/05-troubleshooting.md`.

---

## Exit criteria

- [ ] `podman images` shows `solrise/erpnext:version-15`
- [ ] `make ps` shows every service `Up` (configurator `Exited (0)`)
- [ ] `bench list-apps` lists `erpnext` and `hrms`
- [ ] `http://localhost:8080` serves the Solrise login page
- [ ] `Administrator` can log in with the `.env` password

Next: `docs/02-phase2-module-config.md`.
