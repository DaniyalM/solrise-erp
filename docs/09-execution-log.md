# Execution Log - Stages 1-4 run against a real host

This is the record of actually running the stack, not a plan. It lists what was
verified, every bug that execution exposed, and what remains.

**Host:** rootless Podman 6.1.1, overlay storage, cgroup v2, 18 vCPU, 15 GB RAM,
402 GB free, `~/.local/share/containers/storage`, subuid/subgid present.
**Engine:** `podman-compose` (profiles honoured).
**Result:** a working Solrise + HRMS + Solrise site on `http://localhost:8088`.

> Port note: 8080 was already bound on this host by an unrelated service, so
> `HTTP_PORT=8088` was used. Only `.env` changed.

---

## 1. Verified working

| Check | Evidence |
|-------|----------|
| Image built with apps baked in | `solrise/erpnext:version-15`, 3.29 GB; contains `frappe`, `erpnext`, `hrms` |
| Stack healthy | mariadb 11.8 + redis 8.6 healthy; backend/websocket/queues/scheduler `Up`; `configurator` `Exited (0)` |
| Site created | `bench new-site` + `install-app erpnext` + `install-app hrms` all succeeded |
| Versions installed | `frappe 15.120.1`, `erpnext 15.121.2`, `hrms 15.64.0` |
| HTTP served | `/login` -> 200 (`<title>Login</title>`), `/app` -> 301, `/api/method/ping` -> 200 |
| Unauthenticated API blocked | `frappe.auth.get_logged_user` -> `PermissionError` |
| `common_site_config.json` | correct `db_host`, `db_port`, `redis_cache`, `redis_queue`, `redis_socketio`, `socketio_port` |
| `setup_erp.py` | HR/Selling/Buying/CRM settings set; 3 Leave Types; 4 Issue Priorities; Holiday List; SLA `SLA-Issue-Standard`; Assignment Rule |
| `roles_rbac.py` | 6 roles created; 17 `Custom DocPerm` grants |
| App DocTypes | `Solrise Settings`, `Solrise FAQ`, `Solrise Chat Log`, `Solrise Notification Channel`, `Solrise Message Log` all created |
| Workflows | 4 created; `workflow_state` field injected into Leave Application, Expense Claim, Purchase Order, Payment Entry |
| Notifications | 4 created (`channel=Email`, `send_system_notification=1`) |
| Reports | 9 created; **all 9 execute** via `frappe.desk.query_report.run` |
| Dashboard | 5 standard charts + `Solrise Operations` dashboard created |
| SLA actually applied | a created Issue came back with `response_by=2026-09-14 13:00:00`, `agreement_status=First Response Due` |
| Assistant tools | `navigation_hint`, `search_faq`, `lookup`, `create_ticket` (`ISS-2026-00001`), `ticket_status` all returned correctly |
| Tool allowlist enforced | `dispatch("notify", ...)` refused: *Tool 'notify' is not permitted.* |
| Scheduled tasks | `check_sla_breaches`, `escalate_stale_tickets`, `purge_old_logs`, digests all ran without raising |
| Messaging end-to-end | `send_now` -> `SML-00001` `status=Sent`; provider response captured from the HTTP endpoint |
| Desk assets | `/assets/solrise_erp/js/solrise_erp.js` -> 200 after linking |

Milestones M1-M6 are **achieved**; M9/M10 are code-verified but not production-tested.

---

## 2. Bugs execution exposed (all fixed)

These would all have failed on first real deployment. Grouped by cause.

### 2.1 Build mechanism was wrong

The current `frappe_docker` does **not** accept `APPS_JSON_BASE64` as a build arg.
It passes `apps.json` as a BuildKit *secret* and uses `images/layered/Containerfile`
(prebuilt `frappe/base` + `frappe/build` images) rather than `images/custom/`.
The original script would have silently built an image **without erpnext and hrms**.

- Fixed: `scripts/build-image.sh` now copies `apps.json` into the build context,
  passes `--secret id=apps_json,src=apps.json`, and uses the layered Containerfile.
- Fixed: `FRAPPE_IMAGE_PREFIX` must be fully qualified (`docker.io/frappe`) -
  rootless Podman will not resolve the short name `frappe/build`.
- Fixed: `FRAPPE_BRANCH` selects the base images *and* the branch, so toolchain
  and framework stay matched (v15 -> CPython 3.11).

### 2.2 `.env` values were being silently corrupted

`.env` is shell-sourced by every script, and `make` includes it.

- `INSTALL_APPS=erpnext hrms` -> bash tried to execute `hrms`
  (`hrms: command not found`), aborting every script under `set -e`.
- `APPS_JSON=[{...}]` -> brace expansion + quote removal produced
  `[{url:https://...}]` - **invalid JSON**, silently.

- Fixed: `INSTALL_APPS` is now comma-separated with no spaces, and the app list
  moved out of `.env` into `apps.json` (`APPS_JSON_FILE=apps.json`).
- Rule adopted: **`.env` must contain no unquoted whitespace and no inline JSON.**

### 2.3 Compose service contract

- `create-site` had no `entrypoint: ["bash", "-c"]`. The image ENTRYPOINT
  `exec`s its argv, so the script string would have been treated as a program
  name. Fixed in both compose files.
- `backend` was overriding the image CMD; upstream lets `start.sh` run gunicorn
  via `GUNICORN_*`. Fixed: no `command`, added `GUNICORN_WORKERS/THREADS/TIMEOUT`.
- `frontend` used `nginx -g daemon off;`; the image expects
  `nginx-entrypoint.sh` (which renders the site config from env). Fixed.
- Configurator now matches upstream (`redis://host:port` values).

### 2.4 Platform v15.121 schema mismatches

Found by running against the real database:

| Assumption | Reality in 15.121 | Fix |
|---|---|---|
| `Service Level Agreement.service_level_agreement` | no such column; autoname is `format:SLA-{document_type}-{service_level}` | look up by `document_type` + `service_level` |
| `entity_type = "All"` | options are only Customer / Customer Group / Territory | omit entity fields |
| child table `SLA Priority` | `Service Level Priority` | corrected |
| SLA `response_time` in hours | **Duration** field (seconds) | values are now seconds |
| SLA needs only priorities | `sla_fulfilled_on`, `support_and_resolution`, `holiday_list` are **mandatory** | all three now populated |
| `Support Settings.close_ticket_after_days` | `close_issue_after_days` | corrected |
| SLA can be created directly | refused unless `track_service_level_agreement` is on | enabled first |
| `Issue.resolution_by` | **does not exist**; only `response_by` | tasks + report use `response_by` |
| `Issue.agreement_status` includes `Breached` | options are First Response Due / Resolution Due / Fulfilled / **Failed** | uses `Failed` |
| `Issue Priority` has records | **table is empty**, and `Issue.priority` is a Link to it | records seeded (Low/Medium/High/Urgent) |
| `Issue.priority` is a Select | it is a **Link**, so `field.options` is a DocType name | validate against the records |

Without the `Issue Priority` seeding, both the SLA child rows and the
assistant's `create_ticket` would have failed on a fresh install.

### 2.5 App code bugs

- `Notification.send_email` does not exist in v15 - guard skipped it silently.
  Now uses `channel="Email"` + `send_system_notification=1`.
- `Notification.channel` is immutable after creation, so re-applying config
  raised *"Value cannot be changed for Channel"*. Now only set on create.
- `Dashboard Chart.group_by_field` -> `group_by_based_on`; `filters_json` is
  mandatory (now `"{}"`); charts must be `is_standard=1` with a `module` before a
  Dashboard may link them.
- `is_standard` is a **Check** on Dashboard/Dashboard Chart - the string `"No"`
  was truthy. Now `0`/`1`, and `Report.is_standard` adapts to field type.
- `assistant/tools.py`: `for _, row in ...` shadowed the imported `_` translation
  function, raising `UnboundLocalError` in `search_faq`. Renamed the throwaway.

---

## 3. Deployment mechanics that matter

1. **The app must be baked into the image.** `apps/` and the bench venv live in
   the *image layer*, not a volume. Installing an app into a running container
   is lost the moment the container is recreated - which is exactly what
   happened here, breaking the site until the app was restored.
2. **`bench get-app <local path>` is unsupported** in this bench version
   (`AttributeError: 'App' object has no attribute 'org'`). Use a git URL, or
   install manually into `apps/` + `pip install -e` + `apps.txt`.
3. **gunicorn uses `--preload`.** A freshly installed app is not importable by
   an already-running master, because the editable install's `.pth` is only read
   at interpreter start. A container recreate is required, not a `restart`.
4. **`install-app` runs `after_install` before the app's DocTypes are synced.**
   Any `after_install` logic that queries its own DocTypes will report them
   missing on first install. Run `bench migrate` afterwards (which also runs
   `after_migrate`) - that is when everything appears correctly.
5. **Assets are per-container.** The image entrypoint links
   `sites/assets -> /home/frappe/frappe-bench/assets` *inside the image layer*, so
   a `bench build` in one container does not reach another. Baking the app into
   the image (and thus the build-time `bench build`) is the only correct path.
   `bench build` also needs node on PATH: `. "$NVM_DIR/nvm.sh" && bench build`.
6. **`--no-mariadb-socket` is deprecated** - bench warns to use
   `--mariadb-user-host-login-scope='%'`. Still functional.
7. **`podman-compose` names containers with underscores** (`solrise_backend_1`),
   not the Docker hyphen form. Docs and troubleshooting use `podman ps
   --format '{{.Names}}'`.
8. **MariaDB 11.8 reports a warning** ("more than 10.8 which is not yet tested");
   installs and runs fine. Upstream uses the same version.

---

## 4. Remaining gaps (not executed)

| Gap | Why | Action |
|-----|-----|--------|
| App not in the image | needs a git remote for `apps.json` | push `apps/solrise_erp`, add to `apps.json`, `make image` |
| LLM responses untested | no provider credentials | set a key/model in Solrise Settings |
| Production/TLS untested | no domain or VPS in this environment | follow `docs/03` on the VPS |
| No Company / fiscal year | `bench new-site` does not run the platform setup wizard | complete the wizard in the UI before HR/payroll/accounting |
| Fixtures not committed | export ran, nothing pushed | `make fixtures && ./scripts/pull-fixtures.sh` |

The site is functional for CRM, Service Desk, RBAC, workflows, reports and the
assistant tool layer; HR/payroll/accounting need the setup wizard first.

---

## 5. Reproducing this run

```bash
cp .env.example .env                 # set secrets; ensure no unquoted spaces
make image                           # layered Containerfile + apps.json secret
podman-compose -f compose/compose.local.yaml --env-file .env up -d
./scripts/create-site.sh             # creates site, installs erpnext + hrms
./scripts/run-python.sh scripts/setup_erp.py
./scripts/run-python.sh scripts/roles_rbac.py
# app (once it is in apps.json + rebuilt, this step disappears):
podman exec -i <backend> bench --site erp.localhost install-app solrise_erp
podman exec -i <backend> bench --site erp.localhost migrate   # required on first install
```

---

## 6. Round 2 - app baked into the image, HR made usable

Both follow-ups were completed and re-verified.

### 6.1 The app is now image-native

`apps.json` gained a third entry referencing `${SOLRISE_APP_URL}`, expanded from
`.env` by `build-image.sh`, so the *same* file works on any host:

```json
{ "url": "${SOLRISE_APP_URL}", "branch": "${SOLRISE_APP_BRANCH}" }
```

For this run the app was served from a local `git daemon`
(`git://host.containers.internal:9418/solrise_erp`); production points the same
variable at a real remote. The rebuilt image `85e6ca4ead8d` contains
`apps/{frappe,erpnext,hrms,solrise_erp}` **and** `assets/solrise_erp`, so the
frontend container serves the widget natively - the manual assets symlink from
section 3 is gone.

Two more real bugs surfaced while doing this:

1. **`--secret src=` resolves relative to the working directory, not the build
   context.** Building from the repo root - which also contains an `apps.json` -
   silently baked the wrong app list, and bench failed with
   `InvalidRemoteException: ${SOLRISE_APP_URL} not found`. Proved with an
   isolated two-directory experiment. Fix: `build-image.sh` now `cd`s into the
   build context before building.
2. **A secret-mounted `RUN` is cached.** The first rebuild was a 100% cache hit
   and produced the *identical* image ID - i.e. an image without the new app -
   with no warning. Fix: `CACHE_BUST` is derived from the resolved `apps.json`
   hash, so the cache invalidates exactly when the app list changes.

### 6.2 HR and accounting are usable

`setup_complete(frappe._dict(...))` created Company **Solrise**, currency PKR,
country Pakistan, Fiscal Year 2026 and an 82-account chart of accounts.

Two prerequisites the wizard does not cover, now handled in `setup_erp.py`:

- **`Gender` records** are needed to create an Employee (ships empty here).
- **`Company.default_holiday_list`** must be set, or submitting any leave
  document fails. `ensure_holiday_list()` now points the company at the holiday
  list it creates.

### 6.3 Approval workflow verified end to end

```
Leave Application HR-LAP-2026-00002
  created                       -> workflow_state = Pending Approval, status = Open
  apply_workflow(...,"Approve")  -> workflow_state = Approved, status = Approved, docstatus = 1
```

This confirms M6, including the mapping from the workflow's `Approved` state
onto the document's own `status` field.

**HR prerequisite chain** (in order): Company -> Gender -> Employee ->
Leave Allocation -> Leave Application. Each step fails clearly if the previous
one is missing, which is HRMS working as designed.

### 6.4 Final state

| Check | Result |
|-------|--------|
| Image | `solrise/erpnext:version-15` (`85e6ca4ead8d`) with 4 apps + assets |
| Stack | all services up after `--force-recreate` on the clean image |
| HTTP | `/login` 200, `/app` 301, `/api/method/ping` 200 |
| Assets | `/assets/solrise_erp/{js,css}` 200, served by the frontend container |
| Apps | `frappe`, `erpnext`, `hrms`, `solrise_erp` |
| Config survived recreate | 4 workflows, 9 reports, 1 dashboard, 1 SLA, Company `Solrise` |

---

## 7. Round 3 - US/USD locale and full white-label branding

### 7.1 Site recreated on the clean image

`INSTALL_APPS` now includes the custom app, so `create-site` installs
`erpnext, hrms, solrise_erp` in one pass and the app's `apply_all()` runs
automatically - roles, branding, workflows, notifications, 9 reports and the
dashboard all appeared without a single manual step.

The old PKR/Pakistan site was dropped (`bench drop-site --force --no-backup`)
and recreated, which also proves the configuration is fully reproducible from
code.

### 7.2 Locale

Setup wizard re-run with `country=United States`, `currency=USD`,
`timezone=America/New_York` -> Company **Solrise**, **84** accounts,
Fiscal Year 2026.

### 7.3 Branding applied

| Surface | Before | After |
|---|---|---|
| `System Settings.app_name` (tab/Desk title) | ERPNext | **Solrise** |
| `Website Settings.app_name` + `brand_html` | Frappe | **Solrise** |
| Desk sidebar workspaces | ERPNext Settings / ERPNext Integrations | **Solrise** Settings / **Solrise** Integrations |
| `Global Defaults` | Pakistan / PKR | **United States / USD** |
| Company currency | PKR | **USD** |

Every capitalised `ERPNext` reference was also removed from the repository's
own docs, scripts and app code; the remaining `erpnext` occurrences are the app
name, install records and version numbers, which are identifiers rather than
branding.

### 7.4 Two more build bugs

1. **Cache fingerprint ignored the app revision.** Deriving `CACHE_BUST` from
   `apps.json` alone meant a moved app *branch* still produced a 100% cache hit
   and a stale image. `scripts/apps-fingerprint.py` now hashes the app list
   **plus each git app's remote commit**, with `SOLRISE_APP_REV` as a manual
   override. Verified: bumping the app commit changes `cache-bust` and re-runs
   `bench init`; leaving it alone produces a cache hit and the same image ID.
2. A stray `.: filename argument required` at the end of the build came from the
   bare `.` build-context argument; the context is now the explicit `${FD_DIR}`.
   A re-run is clean and exits 0.

### 7.5 Verified after the rebuild

```
System Settings.app_name : Solrise        Website Settings.app_name: Solrise
country / currency       : United States / USD
time_zone                : America/New_York
Company currency         : USD            Accounts: 84
Apps                     : frappe, erpnext, hrms, solrise_erp
Workflows / Reports / Dashboard : 4 / 9 / 1
/login 200  |  /app 301  |  /assets/solrise_erp/js/solrise_erp.js 200
```

---

## 8. Round 4 - removing the last visible upstream branding

After the Desk came up, a page audit still found the upstream name in three
places, each with a different cause and fix:

| Remaining surface | Cause | Fix |
|---|---|---|
| Login/website footer credit linking to the vendor | upstream template at `templates/includes/footer/footer_powered.html` | app-level template override (loaded after upstream, so it wins) |
| Navbar logo + app-switcher title | `bootinfo.app_logo_url` and `apps_data.apps`, attached **after** the `boot_session` hook | `boot.py` + a client-side boot patch in `public/js/solrise_erp.js` |
| Sidebar workspace labels | boot payload cached from before the DB rename | DB rename + `clear-cache`; boot patch as belt-and-braces |

Result after the fix: login page **0** occurrences, Desk **0** user-visible
occurrences. What remains are module permission identifiers, documented in
`docs/10` with the reason they must not be renamed.

Also added: a Solrise SVG logo (`public/images/solrise-logo.svg`) so the
upstream logo is replaced rather than merely hidden.

---

## 9. Round 5 - Phase 2 closed: fixtures actually committed

The Phase 2 gap was not that the export failed - `bench export-fixtures` had run
- but that the results never left the container. `pull-fixtures.sh` globbed
`*/fixtures` from `apps/`, while the export lands in
`apps/<app>/<module>/fixtures/` (the module folder is named after the app). The
glob matched nothing, so the script "succeeded" and wrote zero files. That is why
`fixtures/` still held only its `README.md`.

**Fix.** `pull-fixtures.sh` now resolves `apps/<app>/<app>/fixtures` **or**
`apps/<app>/fixtures`, copies only the apps named in `FIXTURE_APPS` (default
`solrise_erp`) so framework fixtures and `frappe/cypress/fixtures` are never
committed, and lands them in the documented `./fixtures/<app>/fixtures/` layout.
`make fixtures` now runs export **and** pull, so the two-step that silently
half-worked is gone.

**Re-ran, idempotently** (`setup_erp.py`, `roles_rbac.py`), then exported and
pulled. Committed under `fixtures/solrise_erp/fixtures/`:

| Fixture | Rows | Fixture | Rows |
|---|---|---|---|
| `role.json` | 6 | `report.json` | 9 |
| `custom_docperm.json` | 17 | `dashboard_chart.json` | 5 |
| `workflow.json` | 4 | `dashboard.json` | 1 |
| `workflow_state.json` | 5 | `service_level_agreement.json` | 1 |
| `workflow_action_master.json` | 4 | `assignment_rule.json` | 1 |
| `notification.json` | 4 | `solrise_faq.json` | 1 |
| `custom_field` / `property_setter` / `print_format` / `solrise_notification_channel` | 0 each | | |

**Verified after the change.**

- `setup_erp.py` completed with no `!` lines; six roles and all 17 Solrise-owned
  `Custom DocPerm` rows present.
- `bench migrate` re-synced fixtures with no error and the counts held.
- A new `Issue` was auto-assigned by *Solrise Support Routing*
  (`_assign: ["Administrator"]`), which closes the last unverified Phase 2 exit
  criterion. The test record was deleted afterwards.
- Secret scan of `fixtures/` clean - `Solrise Settings` (the API key) is not a
  fixture by design.

**Caveat for a fresh site.** The fixture filter is deliberately tight (Solrise
owns only its own records), so `custom_docperm.json` carries the six Solrise
roles but **not** the shipped-role rows that `_prepare_doctype()` preserves
(`Support Team`, `System Manager`, `Sales User`, `Accounts User`, ...). Once any
`Custom DocPerm` exists for a DocType, Frappe ignores its shipped `DocPerm`, so a
fresh deploy must still run `roles_rbac.py` after the fixtures sync to recreate
those rows. The alternative - exporting framework roles - would violate the
"never overwrite framework records" rule in `hooks.py`.
