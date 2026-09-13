# Solrise ERP - Master Plan

**Target:** a self-hosted, portable Solrise deployment (CRM, Service Desk, HRMS,
Chat/Assistant, Workflow, Notifications, Reporting, Administration) that runs
identically on rootless Podman locally and on any Ubuntu VPS.

**Status legend:** ✅ done · 🟡 in progress · ⬜ pending · ⛔ blocked

**Last updated:** 2026-09-13

---

## 1. Module scope -> implementation map

| # | Module | Delivered by | Notes |
|---|--------|--------------|-------|
| 1 | CRM | Solrise `crm` | Leads, Opportunities, Quotations, Contacts, Notes |
| 2 | Ticketing / Service Desk | Solrise `support` | Issue, SLA, Assignment Rule, Escalation |
| 3 | HR (HRMS) | `hrms` app | Employee, Leave, Attendance, Payroll inputs |
| 4 | Chat / Virtual Assistant | Custom (Stages 4-5) | LLM responder (Stage 4) + transactional chat entry flow (Phase 5) |
| 5 | Workflow & Approvals | Solrise `Workflow` | Manager/HR/Finance steps + escalation |
| 6 | Notifications | Solrise `Notification` + channel apps | Email, in-app, SMS/WhatsApp |
| 7 | Reporting & Analytics | Solrise reports + custom Query/Dashboard | Pipeline, SLA, HR metrics |
| 8 | Administration | Solrise core | Users, Roles, RBAC, Departments, Audit |

Apps baked into the image: **frappe** + **erpnext** + **hrms** (`apps.json`).
Stage 4 work belongs in a custom app (see `docs/02-phase2-module-config.md`).

---

## 2. Milestones

| ID | Milestone | Phase | Status | Exit criteria |
|----|-----------|-------|--------|---------------|
| M0 | Repo, `.env`, compose, scripts, docs scaffolded | 0 | ✅ | `make help` lists targets; `.env` loads |
| M1 | Custom image builds with erpnext + hrms baked in | 1 | ✅ | `podman images` shows `solrise/erpnext:version-15` |
| M2 | Local stack healthy (db, redis x2, backend, ws, queues, scheduler, frontend) | 1 | ✅ | `make ps` all `Up`; no crash loops in logs |
| M3 | Site created, apps installed, desk reachable | 1 | ✅ | `bench list-apps` shows erpnext, hrms; `http://localhost:8080` returns the login page |
| M4 | Base module settings applied | 2 | ✅ | `setup_erp.py` runs clean and is re-run safe |
| M5 | Roles + RBAC live and exported | 2 | ✅ | Roles exist; Custom DocPerm fixtures committed |
| M6 | Approvals + SLA + assignment rules operational | 2 | ✅ | Workflow triggers on a test record; Issue auto-assigns |
| M7 | Production stack up with valid TLS | 3 | ⬜ | `https://erp.<domain>` serves a trusted certificate |
| M8 | Backup/restore drilled end to end | 3 | ⬜ | Local dump -> SCP -> restore on VPS verified |
| M9 | Notifications wired (email + at least one messaging channel) | 4 | 🟡 | SLA alert arrives; approval mail delivers |
| M10 | Reporting + assistant + audit hardening | 4 | ✅ | Dashboards populated; assistant answers a record lookup |
| M11 | Universal Chat Entry Flow (Desk + Portal) | 5 | ✅ | `turn()` creates/approves as the user; denials audited; widget assets serve 200 |

Update the **Status** column as you go - this table is the single source of truth.

> Stages 1-2 and the Stage 4 code paths have now been **executed**; see
> `docs/09-execution-log.md` for the evidence and the bugs that run exposed.
> ✅ = verified running, 🟡 = code executed but not production-verified,
> ⬜ = not executed. M5 was 🟡 only because the fixtures were pending; they are
> now exported and committed (see `docs/09-execution-log.md` §9).

---

## 3. Phases

### Phase 0 - Repository scaffold ✅
- [x] `.env.example` / `.env` (portable, single source of truth)
- [x] `compose/compose.local.yaml`, `compose/compose.prod.yaml`
- [x] `scripts/` build, site, backup, restore, RBAC, module config
- [x] `config/` Traefik dynamic + MariaDB tuning
- [x] Docs (`PLAN.md` + `01`..`05`)
- **Exit:** `make help` works and every script passes `bash -n`.

### Phase 1 - Local Podman bring-up ✅
- [ ] Rootless Podman subuid/subgid + socket + linger
- [ ] Build custom image (`make image`)
- [ ] Start stack (`make local-up`)
- [ ] Create site + install apps (`make site`)
- [ ] Verify desk, websocket, scheduler, logs
- **Exit:** M1-M3. See `docs/01-phase1-local-podman.md`.

### Phase 2 - Programmatic configuration ✅
- [x] `setup_erp.py` (HR, Selling/Buying, CRM, Support, Leave Types, SLA, Assignment Rule)
- [x] `roles_rbac.py` (custom roles + Custom DocPerm)
- [x] Workflows, Notifications, print/letterhead templates
- [x] Export fixtures; commit them for redeploy (`make fixtures`)
- **Exit:** M4-M6. See `docs/02-phase2-module-config.md`.

### Phase 3 - Production VPS ⬜
- [ ] Bootstrap host (`scripts/bootstrap-vps.sh`)
- [ ] DNS + production `.env` (domain, ports 80/443, secrets)
- [ ] Traefik + Let's Encrypt; named volumes
- [ ] Migrate data local -> VPS
- [ ] Firewall, unattended upgrades, audit log review
- **Exit:** M7-M8. See `docs/03-phase3-production-vps.md`.

### Phase 4 - Integrations & analytics 🟡
- [x] AI assistant / auto-responder (`apps/solrise_erp/assistant/`)
- [x] Audit trail (`Solrise Chat Log`) + scheduled SLA/escalation jobs
- [x] Approval workflows as code - manager, HR, finance + escalation (`workflows.py`)
- [x] Notifications as code - in-app + email (`notifications.py`)
- [x] SMS / WhatsApp gateway (`Solrise Notification Channel`, `channels/`)
- [x] Nine Query Reports + a public dashboard (`reports.py`, `dashboards.py`)
- [x] Log retention policy (`tasks.purge_old_logs`)
- [ ] **Execution:** deploy, configure providers, verify end to end
- **Exit:** M9-M10. See `docs/06`, `docs/07`; run `docs/08-execution-checklist.md`.

### Phase 5 - Universal Chat Entry Flow ✅
- [x] Closed vocabulary, audit store, Settings controls (`chat/registry.py`, DocType `Solrise AI Audit Log`)
- [x] Session context + permission-filtered quick-action menu (`chat/context.py`, `chat/menu.py`)
- [x] Deterministic intent engine + Redis pending-intent state (`chat/nlp.py`, `chat/intent.py`)
- [x] Permission gate with Allowed/Denied auditing (`chat/permissions.py`)
- [x] `get_meta()` schema inspector + conversational slot filling (`chat/schema.py`)
- [x] Executor + workflow bridge + `api.chat.turn` (`chat/executor.py`, `chat/workflow.py`)
- [x] Desk + Portal widget + hardening (`public/js/solrise_chat.js`)
- [ ] **Execution:** human walkthrough of the widget on Desk and Portal
- **Exit:** M11. See `docs/12-phase5-universal-chat-entry-flow.md`.

---

## 4. Repository map

```
.
├── .env.example            # portable config - copy to .env and edit
├── apps.json               # apps baked into the custom image (erpnext + hrms)
├── apps.example.json       # same list plus the solrise_erp custom app
├── apps/solrise_erp/       # custom app: RBAC, SLA tasks, AI assistant layer
├── Makefile                # single entry point for every task
├── compose/
│   ├── compose.local.yaml  # Podman testing stack (no TLS)
│   └── compose.prod.yaml   # VPS stack + Traefik + Let's Encrypt
├── config/
│   ├── traefik/dynamic.yaml
│   └── mariadb/conf.d/solrise.cnf
├── scripts/
│   ├── lib.sh              # shared env/engine helpers
│   ├── build-image.sh      # frappe + erpnext + hrms image
│   ├── create-site.sh      # bring up + new-site + install apps
│   ├── run-python.sh       # run a python file inside backend
│   ├── setup_erp.py        # Stage 2 module configuration
│   ├── roles_rbac.py       # Stage 2 roles + permissions
│   ├── export-fixtures.sh  # bench export-fixtures
│   ├── pull-fixtures.sh    # copy fixtures out of the container
│   ├── backup.sh           # dump + stream to host
│   ├── restore.sh          # restore onto any stack/VPS
│   └── bootstrap-vps.sh    # Ubuntu host preparation
├── fixtures/               # committed exports (durable config)
└── docs/                   # PLAN + 01..12 guides, runbook, checklist, execution log, branding
```

---

## 5. Environment matrix

| Concern | Local (CachyOS) | Production (VPS) |
|---------|-----------------|------------------|
| Engine | rootless Podman | Podman or Docker |
| Compose | `podman-compose` | `podman-compose` / `docker compose` |
| Compose file | `compose.local.yaml` | `compose.prod.yaml` |
| TLS | none | Traefik + Let's Encrypt |
| HTTP port | `8080` | `80` / `443` |
| Site name | `erp.localhost` | `erp.<yourdomain>.com` |
| developer_mode | `1` | `0` |
| Data | named volumes | named volumes + off-host backups |

Only `DOMAIN`, `LETSENCRYPT_EMAIL`, the passwords and the ports differ. Nothing
in this repo is tied to one host, provider or engine.
