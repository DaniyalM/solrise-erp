# Execution Checklist

The run order for going from a checked-out repo to a live system. Each step lists
the command, what success looks like, and where to go when it does not.

> **This checklist has been executed.** Stages 1-2 and the Stage 4 code paths were
> run against a real host; `docs/09-execution-log.md` records the evidence and the
> bugs that run exposed. Corrections from that run are folded in below.

Work top to bottom. Do not skip the verification lines - they are what keep a
failure from surfacing three steps later.

---

## Pre-flight (5 minutes)

```bash
cd solrise-erp
cp .env.example .env
chmod +x scripts/*.sh
make help                 # every target listed
```

- [ ] `podman --version` and `podman-compose --version` succeed
- [ ] `.env` exists and is **not** tracked by git (`git check-ignore .env`)
- [ ] `grep "^$USER:" /etc/subuid /etc/subgid` shows a range
- [ ] Free disk >= 8 GB, RAM >= 4 GB
- [ ] Your chosen `HTTP_PORT` is free: `ss -ltn | grep :8080` (if it is taken,
      set another port in `.env` - nothing else changes)

Go/no-go: if `podman-compose` is missing, install it (`sudo pacman -S podman-compose`)
or set `COMPOSE_CMD="podman compose"` in `.env`.

---

## Stage 1 - Local bring-up

### 1.1 Configure

```bash
$EDITOR .env
```

Set `SITE_NAME=erp.localhost`, a strong `ADMIN_PASSWORD`, `DB_ROOT_PASSWORD`,
`DB_PASSWORD`, and `COMPOSE_CMD=podman-compose`.

- [ ] Secrets are unique (not the `change-me-*` placeholders)

### 1.2 Build the image

```bash
make image
```

- [ ] `podman images | grep solrise` shows `solrise/erpnext  version-15`
- [ ] Expected: 10-25 min first run, ~1 min after

Failure: the build stops resolving the base image -> set
`FRAPPE_IMAGE_PREFIX=docker.io/frappe` (rootless Podman will not resolve a short
name). `apps.json` - not `.env` - is the app list; validate it with
`python3 -c "import json;json.load(open('apps.json'))"`.

### 1.3 Start the stack

```bash
make local-up
make ps
```

- [ ] `mariadb`, `redis-cache`, `redis-queue`, `backend`, `websocket`,
      `queue-short`, `queue-long`, `scheduler`, `frontend` all `Up`
- [ ] `configurator` shows `Exited (0)`

Failure: backend restarting before the configurator finished ->
`podman-compose -f compose/compose.local.yaml --env-file .env restart backend queue-short queue-long scheduler websocket`.

### 1.4 Create the site

```bash
make site
```

- [ ] `bench list-apps` prints `frappe`, `erpnext`, `hrms`
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080` returns `200` or `302`
- [ ] `http://localhost:8080` shows the Solrise login page
- [ ] `Administrator` + `ADMIN_PASSWORD` logs in

**Milestones M1-M3 complete.**

---

## Stage 2 - Configuration as code

### 2.1 Module settings

```bash
./scripts/run-python.sh scripts/setup_erp.py
```

- [ ] No `!` lines in the output (warnings only for fields absent in this version)
- [ ] Re-running produces `= exists` / `= updated`, never a duplicate error

### 2.2 Roles and permissions

```bash
./scripts/run-python.sh scripts/roles_rbac.py
```

- [ ] All six roles reported created or existing
- [ ] `bench --site erp.localhost execute frappe.client.get_count --kwargs "{'doctype':'Role'}"` includes `Support Manager`

### 2.3 App-level configuration

If the custom app is in the image (Stage 4.1), `bench migrate` already applied
workflows, notifications, reports and dashboards.

> **First install ordering.** `install-app` runs `after_install` *before* the
> app's DocTypes are synced, so reports and dashboard charts that reference its
> own DocTypes are skipped on that first pass. Always follow an `install-app`
> with a `migrate` before judging the result.

Force a re-apply:

```bash
podman exec -it solrise-backend bench --site erp.localhost execute \
  solrise_erp.install.apply_all
```

- [ ] Four approval workflows exist (`bench console` -> `frappe.get_all("Workflow", pluck="name")`)
- [ ] Nine reports appear in **Desk -> Reports** under `Solrise *`
- [ ] **Solrise Operations** dashboard renders

### 2.4 Verify behaviour, then lock it in as fixtures

```bash
# create a Leave Application in the UI; it should enter "Pending Approval"
# create an Issue; it should be assigned by the Assignment Rule
make fixtures
./scripts/pull-fixtures.sh
git add fixtures && git commit -m "chore: capture Solrise configuration"
```

- [ ] Leave Application shows the workflow action buttons
- [ ] New Issue is auto-assigned (check `_assign`)
- [ ] `fixtures/` contains JSON for roles, workflows, reports, notifications

### 2.5 Company setup (required before HR and accounting)

`bench new-site` does **not** run the platform setup wizard, so a fresh site has
no Company. CRM and Service Desk work without one, but HR, payroll and
accounting do not: leave documents fail with *"Please set a default Holiday
List for Employee ... or Company ..."*.

```bash
podman exec -i solrise-backend bash -lc 'cd /home/frappe/frappe-bench/sites && ../env/bin/python - ' <<'EOF'
import frappe
frappe.init(site="erp.localhost", sites_path="/home/frappe/frappe-bench/sites")
frappe.connect(); frappe.set_user("Administrator")
from erpnext.setup.setup_wizard.setup_wizard import setup_complete
setup_complete(frappe._dict({
    "language": "English", "country": "United States", "timezone": "America/New_York",
    "currency": "USD", "company_name": "Solrise", "company_abbr": "SOL",
    "chart_of_accounts": "Standard", "fy_start_date": "2026-01-01",
    "fy_end_date": "2026-12-31", "domain": "Services", "setup_demo": 0,
}))
frappe.db.commit(); frappe.destroy()
EOF
```

- [ ] `Company` list is non-empty; currency and country are correct
- [ ] `Account` count > 0 (chart of accounts installed)
- [ ] `./scripts/run-python.sh scripts/setup_erp.py` sets the company's default Holiday List

> `setup_complete` needs **attribute** access, so pass `frappe._dict(...)` - a plain
> dict fails with `'dict' object has no attribute 'fy_start_date'`.

**Milestones M4-M6 complete.**

---

## Stage 3 - Production

### 3.1 Prepare the VPS

```bash
# on the VPS, as root, from a clone of this repo
sudo SWAP_SIZE=4G DEPLOY_USER=$SUDO_USER ./scripts/bootstrap-vps.sh
```

- [ ] `free -h` shows swap
- [ ] `sysctl net.ipv4.ip_unprivileged_port_start` returns `80`
- [ ] `sudo ufw status` shows 22/80/443 allowed
- [ ] `grep "^$USER:" /etc/subuid /etc/subgid` shows a range

### 3.2 DNS and production `.env`

```bash
dig +short erp.yourdomain.com      # must return the VPS IP
$EDITOR .env
```

Set `SITE_NAME` and `DOMAIN` to `erp.yourdomain.com`, `HTTP_PORT=80`,
`HTTPS_PORT=443`, `DOCKER_SOCK=/run/user/<uid>/podman/podman.sock`, and new
passwords.

- [ ] DNS resolves to the VPS
- [ ] `chmod 600 .env`
- [ ] Provider firewall (hPanel) allows 80/443 as well as ufw

### 3.3 Deploy

```bash
make image
SITE_ENV=prod make prod-up
SITE_ENV=prod make site
```

- [ ] All services `Up`, `traefik` healthy
- [ ] `curl -I https://erp.yourdomain.com` returns a trusted certificate
- [ ] `http://` redirects to `https://`

Failure: certificate not issued -> confirm port 80 is reachable from the
internet and the Cloudflare proxy is off (grey cloud) for the first issuance.

### 3.4 Migrate data from local

```bash
# local machine
make backup
scp -r backups/<stamp> root@<vps>:/root/solrise-backup-<stamp>

# on the VPS
mkdir -p backups && cp -r /root/solrise-backup-<stamp> backups/
SITE_ENV=prod ./scripts/restore.sh backups/solrise-backup-<stamp> --new
```

- [ ] Login works and CRM/Issue/Employee records are present
- [ ] A report renders with real data
- [ ] `rm -rf /root/solrise-backup-*` afterwards

**Milestones M7-M8 complete.**

---

## Stage 4 - Assistant, notifications, reporting

### 4.1 Put the custom app in the image

```bash
cp apps.example.json apps.json      # then set your git remote
$EDITOR apps.json                   # add the solrise_erp entry
make image                          # bakes app + assets into the image
SITE_ENV=prod make prod-up
podman exec -it solrise-backend bench --site erp.yourdomain.com install-app solrise_erp
podman exec -it solrise-backend bench --site erp.yourdomain.com migrate
```

> Do **not** shortcut this by installing the app into a running container: `apps/`
> and the bench virtualenv are in the image layer, so a container recreate wipes
> the app while the site still lists it as installed - which breaks the site.
> Baking it in also makes the app's assets visible to the frontend container.

- [ ] `bench list-apps` includes `solrise_erp`

### 4.2 Assistant provider

In **Solrise Settings**: `enabled`, `provider`, `api_base_url`, `api_key`, `model`.

- [ ] `bench execute solrise_erp.api.v1.health` returns `assistant_enabled: true`
- [ ] `engine.ask("How do I reset my password?")` in a console returns a reply
- [ ] The "Ask Solrise" navbar button opens the widget and answers
- [ ] `Solrise Chat Log` has rows for the turn

### 4.3 Messaging channel

Create a **Solrise Notification Channel**, then in **Solrise Settings** enable
messaging and pick the default channel.

- [ ] `send_test_message` returns `status: Sent`
- [ ] `Solrise Message Log` shows the row with a provider response
- [ ] Deliberately force an SLA breach; an SMS arrives and the log says `Sent`

### 4.4 Reporting and retention

- [ ] All nine `Solrise *` reports run without SQL errors
- [ ] **Solrise Operations** dashboard renders all five charts
- [ ] `enable_log_purge` on; retention values match policy
- [ ] `bench execute solrise_erp.tasks.purge_old_logs` returns a dict of counts

**Milestones M9-M10 complete.**

---

## Post-deploy hardening

- [ ] SSH password auth disabled; key access confirmed first
- [ ] `unattended-upgrades` enabled
- [ ] 2FA on `Administrator`; named users assigned Stage 2 roles
- [ ] Daily backup cron installed and an off-site copy configured
- [ ] A restore rehearsed into a throwaway stack
- [ ] `.env` and secrets stored in a password manager
- [ ] Report list reviewed - remove any `Solrise *` report the business does not need

---

## Rollback

| Situation | Action |
|-----------|--------|
| Bad image tag | set `CUSTOM_TAG` back, `make image`, `SITE_ENV=prod make prod-up` |
| Bad migration | `SITE_ENV=prod ./scripts/restore.sh <last-good-backup>` |
| Bad config-only change | `git revert`, `podman exec ... bench migrate` |
| Certificate trouble | verify port 80 + DNS; use the LE staging endpoint while debugging |

---

## Reference

| Doc | Contents |
|-----|----------|
| `docs/01-phase1-local-podman.md` | local bring-up detail |
| `docs/02-phase2-module-config.md` | setup_erp.py, RBAC, fixtures |
| `docs/03-phase3-production-vps.md` | VPS, Traefik, TLS, migration |
| `docs/04-operations-runbook.md` | backups, upgrades, scaling |
| `docs/05-troubleshooting.md` | symptom -> cause -> fix |
| `docs/06-phase4-assistant.md` | assistant guardrails and tools |
| `docs/07-phase4-notifications-reporting.md` | channels, reports, dashboards, retention |
