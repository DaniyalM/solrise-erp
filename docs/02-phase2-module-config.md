# Stage 2 - Programmatic Configuration, RBAC and Fixtures

**Goal:** configure every module from code so a fresh deployment is
reproducible, and export those customisations as fixtures that re-apply on any
future VPS.

**Milestones covered:** M4 (module settings), M5 (RBAC), M6 (approvals + SLA).

---

## 2.0 How the Python scripts run

Anything that touches the database must run **inside the backend container**.
`scripts/run-python.sh` pipes a Python file into the bench virtualenv:

```bash
./scripts/run-python.sh scripts/setup_erp.py
SITE_ENV=prod ./scripts/run-python.sh scripts/setup_erp.py   # against a VPS stack
```

> `make site` (`scripts/create-site.sh`) runs `setup_erp.py` and `roles_rbac.py`
automatically once the apps are installed, so one command leaves a fresh site
fully configured. Both scripts are idempotent, so re-running `make site` is safe.
Opt out with `SKIP_CONFIG=1 make site`.

The scripts are self-bootstrapping, so they also work through the console:

```bash
podman exec -it solrise-backend bench --site erp.localhost console < scripts/setup_erp.py
```

Both paths end up here:

```python
frappe.init(site=SITE_NAME, sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()
frappe.set_user("Administrator")
```

---

## 2.1 Module settings - `scripts/setup_erp.py`

Run it:

```bash
make local-up                       # stack must be running
./scripts/run-python.sh scripts/setup_erp.py
```

What it configures (all values are constants at the top of the file):

| Area | Object | Notes |
|------|--------|-------|
| HR | `HR Settings` Single | employee naming, approver mandates |
| HR | `Leave Type` docs | Casual / Sick / Earned, with max days + encashment |
| Selling | `Selling Settings` Single | customer naming, SO/DN required |
| Buying | `Buying Settings` Single | PO/PR required, same-rate check |
| CRM | `CRM Settings` Single | opportunity ageing |
| Support | `Support Settings` Single | auto-close window |
| Support | `Service Level Agreement` | default SLA with per-priority targets |
| Support | `Assignment Rule` | round-robin routing of new Issues |

### Design notes

- **Idempotent.** Records are looked up by a natural key before creation, and
  Singles are updated in place. Re-running is always safe.
- **Version-safe.** Every Single field is written through
  `frappe.get_meta(doctype).has_field(...)`, so if the upstream apps move a field in a
  point release the script prints `skip ... (field not in this version)` instead
  of crashing. Watch the output and adjust the constants.
- **Fault-isolated.** Each section is wrapped in `try/except` with a rollback,
  so one bad doctype does not stop the rest.

### Editing the policy

Everything you are expected to change is between the `EDIT HERE` markers:

```python
LEAVE_TYPES = [
    {"leave_type_name": "Casual Leave", "max_days_allowed": 12, ...},
    ...
]
SLA_PRIORITIES = [
    {"priority": "Urgent", "response_time": 0.5, "resolution_time": 4},
    ...
]
```

Confirm the SLA targets against your installed version: `response_time` /
`resolution_time` follow whatever the `SLA Priority` DocType expects in your
version (check the field labels in the DocType). Adjust the numbers, not the
schema.

---

## 2.2 Custom roles and RBAC - `scripts/roles_rbac.py`

```bash
./scripts/run-python.sh scripts/roles_rbac.py
```

It creates roles and grants **Custom DocPerm** rows:

| Role | Representative access |
|------|-----------------------|
| `Support Agent` | Issue: read/write/create; permlevel 1 `if_owner` |
| `Support Manager` | Issue: full + delete/export/share; SLA + Assignment Rule |
| `CRM User` | Lead, Opportunity, Quotation, Contact |
| `CRM Manager` | as CRM User + delete/submit/cancel/amend |
| `Finance Approver` | Payment Entry submit, PO/SI submit |
| `Solrise Admin` | role only; used for workflow steps |

### Why `Custom DocPerm`, not `DocPerm`

`DocPerm` belongs to the DocType and is overwritten when an app updates. A
`Custom DocPerm` lives in the database as user data, so it is exportable as a
fixture and survives upgrades. The script normalises all boolean permission
fields on every run and clears the DocType cache afterwards, which is what makes
a permission change take effect without a restart:

```python
frappe.clear_cache(doctype=doctype)
```

### Adding a grant

Append to `GRANTS`:

```python
"Support Agent": [
    ("Issue", 0, {"read": 1, "write": 1, "create": 1}),
    ("HD Ticket", 0, {"read": 1, "write": 1, "create": 1}),   # extra DocType
],
```

`permlevel 0` = document-level, `permlevel 1` = field-level (restricted fields).
Combine with `if_owner: 1` to restrict a user to records they created.

---

## 2.3 Workflows and approvals

Approvals are Frappe `Workflow` documents. Create them programmatically the
same way as any other DocType. Example - a two-step leave approval:

```python
import frappe

wf = frappe.get_doc({
    "doctype": "Workflow",
    "workflow_name": "Solrise Leave Approval",
    "document_type": "Leave Application",
    "workflow_state_field": "workflow_state",
    "is_active": 1,
    "send_email_alert": 1,
    "states": [
        {"state": "Pending Approval", "doc_status": "0", "allow_edit": "HR User"},
        {"state": "Approved",         "doc_status": "1", "allow_edit": "HR Manager"},
        {"state": "Rejected",         "doc_status": "0", "allow_edit": "HR Manager"},
    ],
    "transitions": [
        {"state": "Pending Approval", "action": "Approve",
         "next_state": "Approved", "allowed": "HR Manager",
         "allow_self_approval": 0},
        {"state": "Pending Approval", "action": "Reject",
         "next_state": "Rejected", "allowed": "HR Manager"},
    ],
})
wf.insert(ignore_permissions=True)
frappe.db.commit()
```

Notes:

- Run it the same way: put it in a file and use
  `./scripts/run-python.sh <file>.py`, or extend `setup_erp.py`.
- The `Workflow` controller creates the referenced `Workflow State` and
  `Workflow Action Master` records on save if they are missing.
- `workflow_state_field` must be a field on the target DocType. Frappe adds
  `workflow_state` to the DocType via a `Property Setter` on first use.
- Model escalation as extra transitions (e.g. a "Escalated" state reachable only
  by a `Solrise Admin`), or as a `Notification` that fires on ageing.

Repeat the same pattern for finance (`Payment Entry`, `Purchase Order`) and
manager (`Expense Claim`, `Purchase Order`) approvals.

> **Already implemented.** The custom app ships four ready workflows - leave,
> expense, purchase order and payment - each with an `Escalated` state reachable
> by `Solrise Admin`. See `apps/solrise_erp/workflows.py` and
> `docs/07-phase4-notifications-reporting.md`. The snippet above is the pattern
> to follow when adding your own.

---

## 2.4 Notifications

`Notification` documents cover email, in-app and (with a channel app) SMS /
WhatsApp. Example - alert Support Managers when an Issue passes its SLA target:

```python
import frappe

if not frappe.db.exists("Notification", "Solrise SLA Breach Alert"):
    frappe.get_doc({
        "doctype": "Notification",
        "name": "Solrise SLA Breach Alert",
        "enabled": 1,
        "document_type": "Issue",
        "event": "Value Change",
        "value_changed": "status",
        "condition": "doc.status == 'Open'",
        "channel": "System Notification",
        "send_system_notification": 1,
        "send_email": 1,
        "subject": "SLA attention needed: {{ doc.name }}",
        "message": "Issue {{ doc.name }} is still {{ doc.status }}.",
        "recipients": [{"receiver_by_role": "Support Manager"}],
    }).insert(ignore_permissions=True)
    frappe.db.commit()
```

Use `Notifier`/`Notification Log` for bespoke in-app pushes, and configure
outgoing mail in **Email Account** (SMTP) with the credentials for your provider.

> **SMS/WhatsApp is built in.** Instead of a separate gateway app, create a
> **Solrise Notification Channel** (Meta WhatsApp Cloud API, Twilio, or a Generic
> HTTP endpoint), enable messaging in **Solrise Settings**, and let
> `solrise_erp.channels.dispatcher` queue and audit every send. See
> `docs/07-phase4-notifications-reporting.md`. Credentials live in encrypted
> `Password` fields, never in source, and are excluded from fixtures.
>
> The app also ships four ready `Notification` documents via
> `apps/solrise_erp/notifications.py`.

---

## 2.5 Fixtures - making it all survive redeployment

Fixtures are JSON dumps of records that Frappe re-imports during `bench migrate`.

### a. Declare what to export

This list belongs in the `hooks.py` of a custom app (see 2.6). Filters keep the
export to Solrise-owned records so you never overwrite framework data:

```python
# solrise_erp/hooks.py
fixtures = [
    {"dt": "Custom Field",   "filters": [["module", "in", ["Solrise ERP"]]]},
    {"dt": "Property Setter","filters": [["module", "in", ["Solrise ERP"]]]},
    {"dt": "Custom DocPerm", "filters": [["role", "in", [
        "Support Agent", "Support Manager", "CRM User", "CRM Manager",
        "Finance Approver", "Solrise Admin"]]]},
    {"dt": "Role",           "filters": [["role_name", "in", [
        "Support Agent", "Support Manager", "CRM User", "CRM Manager",
        "Finance Approver", "Solrise Admin"]]]},
    {"dt": "Workflow"},
    {"dt": "Workflow State"},
    {"dt": "Workflow Action Master"},
    {"dt": "Notification",   "filters": [["name", "like", "Solrise%"]]},
    {"dt": "Service Level Agreement"},
    {"dt": "Assignment Rule"},
    {"dt": "Print Format",   "filters": [["module", "in", ["Solrise ERP"]]]},
]
```

### b. Export and bring the files out of the container

```bash
make fixtures                 # export inside the container + pull into ./fixtures/<app>/fixtures/
```

`bench export-fixtures` writes to `apps/<app>/<module>/fixtures/` (the module
folder is named after the app), **not** `apps/<app>/fixtures/`. `pull-fixtures.sh`
resolves either layout, pulls only the apps in `FIXTURE_APPS` (default
`solrise_erp`) so framework and test fixtures are never committed, and lands them
in the documented `./fixtures/<app>/fixtures/` layout.

`fixtures/` is committed to git. Because the apps live in the image (not a
volume), **anything exported and not committed is lost on the next rebuild** -
always commit.

### c. How they re-apply on a new deployment

1. `scripts/build-image.sh` bakes your custom app into the image (`apps.json`).
2. `scripts/create-site.sh` runs `bench install-app`, which runs `bench migrate`.
3. `bench migrate` calls `sync_fixtures()` for each installed app and writes the
   records in `fixtures/` back into the database.

To force a re-sync on an existing site:

```bash
podman exec -it solrise-backend bench --site erp.localhost migrate
```

---

## 2.6 The durable home: a custom app

Fixtures and Stage 4 code (assistant, channels, reports) need an app that owns
them. Create it once:

```bash
podman exec -it solrise-backend bench new-app solrise_erp
# edit apps/solrise_erp/solrise_erp/hooks.py -> add the fixtures list above
podman exec -it solrise-backend bench --site erp.localhost install-app solrise_erp
```

Then make it reproducible on any host:

```bash
# push the app to your git remote
cd apps/solrise_erp && git remote add origin <your-app-repo> && git push -u origin main
```

and add it to `apps.json` + `APPS_JSON` in `.env`:

```json
[
  {"url": "https://github.com/frappe/erpnext", "branch": "version-15"},
  {"url": "https://github.com/frappe/hrms",    "branch": "version-15"},
  {"url": "https://github.com/<you>/solrise_erp", "branch": "main"}
]
```

Rebuild (`make image`) and the custom app is part of the image forever.

---

## Exit criteria

- [x] `./scripts/run-python.sh scripts/setup_erp.py` completes with no `!` lines
- [x] `./scripts/run-python.sh scripts/roles_rbac.py` creates all six roles
- [x] A test `Leave Application` shows the "Pending Approval" workflow state
- [x] A new `Issue` is auto-assigned by the Assignment Rule (`_assign` set on insert)
- [x] `fixtures/` contains committed JSON and reapplies after `make image`

> All five were verified against the running stack on 2026-09-12 and are
> recorded in `docs/09-execution-log.md` §9. A fresh site still needs
> `roles_rbac.py` to run after the fixtures sync so the shipped roles preserved
> in `Custom DocPerm` are recreated.

Next: `docs/03-phase3-production-vps.md`.
