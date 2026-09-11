# Operations Runbook

Day-two operations for both environments. Every command takes `SITE_ENV=local`
(default) or `SITE_ENV=prod`.

---

## 1. Status and health

```bash
make ps                      # local
SITE_ENV=prod make ps        # production
make logs                    # tail local
SITE_ENV=prod make prod-logs # tail production
```

Per-service logs:

```bash
podman logs --tail=100 <container-name>       # list with: podman ps --format '{{.Names}}'
podman logs -f --since 10m <container-name>
```

Quick health probes:

```bash
curl -s -o /dev/null -w 'frontend %{http_code}\n' http://localhost:8080
SITE_ENV=prod ./scripts/run-python.sh scripts/health_check.py   # see below
```

A tiny `health_check.py` you can keep next to the other scripts:

```python
import os, frappe
if not getattr(frappe.local, "site", None):
    frappe.init(site=os.environ["SITE_NAME"], sites_path="/home/frappe/frappe-bench/sites")
    frappe.connect()
frappe.set_user("Administrator")
print("site        :", frappe.local.site)
print("apps        :", ", ".join(frappe.get_installed_apps()))
print("users       :", frappe.db.count("User", {"enabled": 1}))
print("open issues :", frappe.db.count("Issue", {"status": "Open"}))
print("pending msgs:", frappe.db.count("Error Log"))
```

---

## 2. Backups

### 2.1 Manual, on demand

```bash
make backup                          # local
SITE_ENV=prod ./scripts/backup.sh    # production
```

Produces, in `./backups/<timestamp>/`:

| File | Contents |
|------|----------|
| `*-database.sql.gz` | full SQL dump |
| `*-files.tar` | public files (attachments on documents) |
| `*-private-files.tar` | private files |

### 2.2 Automated daily backup (recommended)

On the VPS crontab (`crontab -e`):

```cron
# 02:15 every day - database + files
15 2 * * * cd /home/deploy/solrise-erp && SITE_ENV=prod BACKUP_DIR=/var/backups/solrise ./scripts/backup.sh >> /var/log/solrise-backup.log 2>&1
```

`BACKUP_RETENTION_DAYS` (default 14) prunes local copies automatically.

### 2.3 Off-site copy

A backup on the same VPS is not a backup. Push it somewhere else:

```bash
# Example: rsync to a second host
rsync -az --delete /var/backups/solrise/ backup@other-host:/srv/solrise-backups/

# Example: object storage via rclone (configure a remote first)
rclone sync /var/backups/solrise/ remote:solrise-erp-backups
```

Add whichever you choose to the same cron block.

### 2.4 Restore

```bash
# Into an existing stack (overwrites the current database)
SITE_ENV=prod ./scripts/restore.sh backups/20260912-101500

# Onto a brand-new stack: create the empty site first, then restore
SITE_ENV=prod ./scripts/restore.sh backups/20260912-101500 --new
```

The script locates the `*-database.sql.gz`, `*-files.tar` and
`*-private-files.tar` in the directory, streams them into the container, runs
`bench --force restore`, then `bench migrate` and `bench clear-cache`.

**Test the restore path at least once into a throwaway stack** before you need
it. A backup you have never restored is an untested backup.

---

## 3. Upgrades

### 3.1 Config/script-only change

```bash
git pull
make image
make local-up          # or: SITE_ENV=prod make prod-up
```

### 3.2 Frappe / app version bump

1. **Back up first:** `SITE_ENV=prod ./scripts/backup.sh`
2. Edit `.env`: bump `CUSTOM_TAG`, `FRAPPE_BRANCH`, and the branches in
   `APPS_JSON` + `apps.json` together.
3. Rebuild and recreate:

```bash
make image
SITE_ENV=prod make prod-up
podman exec -it solrise-backend bench --site erp.yourdomain.com migrate
podman exec -it solrise-backend bench --site erp.yourdomain.com clear-cache
```

4. Watch for schema failures:

```bash
podman logs --tail=200 <backend-container>
```

> Pin versions in `.env` rather than tracking `latest`. If a migration fails you
> want to be able to set the tag back and redeploy the previous image.

### 3.3 Rolling back

Images are tagged, so rollback is: set `CUSTOM_TAG` back to the previous tag,
`make prod-up`, and (if the migration was destructive) restore the backup taken
in step 1.

---

## 4. Scaling workers

Background work (emails, SLA checks, imports) is handled by `queue-short` and
`queue-long`. To add capacity, run more replicas:

```bash
podman-compose -f compose/compose.prod.yaml --env-file .env \
  up -d --scale queue-short=3 --scale queue-long=2
```

Long-running jobs go to the `long` queue; keep that queue sized for your import
volume, and keep `short` responsive for user-triggered actions.

---

## 5. Maintenance mode and cache

```bash
# Put the site in maintenance mode while you restore/upgrade
podman exec -it solrise-backend bench --site erp.yourdomain.com set-maintenance-mode on
podman exec -it solrise-backend bench --site erp.yourdomain.com set-maintenance-mode off

# Clear caches without a restart
podman exec -it solrise-backend bench --site erp.yourdomain.com clear-cache
podman exec -it solrise-backend bench --site erp.yourdomain.com clear-website-cache
```

---

## 6. Log locations

| What | Where |
|------|-------|
| Container stdout | `podman logs <container>` |
| Frappe web log | `sites/<site>/logs/web.log` (inside `solrise_sites`) |
| Worker/scheduler logs | `sites/<site>/logs/worker.*.log`, `scheduler.log` |
| Backup script log | `/var/log/solrise-backup.log` (if cron is set up) |
| Traefik access log | `podman logs <traefik-container>` |
| In-app errors | Solrise **Error Log**, **Activity Log** |

---

## 7. Certificate renewal

Traefik renews automatically. Verify with:

```bash
openssl s_client -connect erp.yourdomain.com:443 -servername erp.yourdomain.com </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

If renewal fails, check that port 80 is reachable from the internet (the HTTP-01
challenge needs it) and that the `solrise_letsencrypt` volume is intact.

---

## 8. Messaging channels and log retention

### Inspecting outbound messages

```bash
podman exec -it solrise-backend bench --site erp.localhost mariadb -e \
  "select name, channel, status, retry_count, creation
     from \`tabSolrise Message Log\`
    order by creation desc limit 20;"
```

Or open **Solrise Message Log** in the Desk and filter by `Status`. A `Failed`
row carries the provider's raw HTTP response in **Provider Response** - that is
the first place to look when a message does not arrive.

### Re-sending a failed message

```python
# in a bench console
from solrise_erp.channels import dispatcher
dispatcher.deliver("SML-00042")          # retries in place, updates the row
```

### Testing credentials after a change

```python
frappe.call("solrise_erp.api.v1.send_test_message", {"channel": "Support WhatsApp"})
```

`Skipped` means the dispatcher declined to send rather than failing: no enabled
channel, the channel rate limit was hit, or the provider name is unknown.

### Log retention

Configured in **Solrise Settings**:

| Setting | Default | Applies to |
|---------|---------|-----------|
| `enable_log_purge` | on | master switch |
| `chat_log_retention_days` | 90 | `Solrise Chat Log` |
| `message_log_retention_days` | 180 | `Solrise Message Log` |

`solrise_erp.tasks.purge_old_logs` runs daily at 03:00 and bulk-deletes rows
older than the window. Run it manually to check the counts:

```bash
podman exec -it solrise-backend bench --site erp.localhost execute \
  solrise_erp.tasks.purge_old_logs
```

Chat logs contain user text and record names. Treat retention as a
data-protection control and review it with whoever owns compliance.
