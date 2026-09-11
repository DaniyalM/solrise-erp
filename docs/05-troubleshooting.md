# Troubleshooting

Symptom -> cause -> fix. Check `make logs` and `podman ps` first; most issues
are visible as a crash-looping service.

---

## Local Podman

### `Permission denied` writing to a mounted volume

Rootless Podman maps container UID 1000 to your host UID. Named volumes handle
this automatically; bind mounts do not.

- Switch to named volumes (this repo's default), **or**
- annotate the bind mount with `:U`:

  ```yaml
  volumes:
    - ./sites:/home/frappe/frappe-bench/sites:U
  ```

- Confirm ranges exist: `grep "^$USER:" /etc/subuid /etc/subgid`. If missing:
  `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"`
  then `podman system migrate`.

### Backend starts before `configurator` finishes

`podman-compose` only partially supports
`depends_on: condition: service_completed_successfully`.

```bash
podman-compose restart backend queue-short queue-long scheduler websocket
```

Verify the config file exists:

```bash
podman exec -it solrise-backend cat sites/common_site_config.json
```

It must contain `db_host`, `redis_cache`, `redis_queue`, `socketio_port`.

### `bench new-site` fails: "Access denied for user root"

The MariaDB container was not healthy yet, or `DB_ROOT_PASSWORD` changed after
the `db-data` volume was first created.

```bash
make logs | grep -i mariadb
# If the password was changed: reset the data volume (DESTROYS DATA)
podman-compose -f compose/compose.local.yaml --env-file .env down -v
make local-up site
```

### `erp.localhost` does not resolve

```bash
echo '127.0.0.1 erp.localhost' | sudo tee -a /etc/hosts
```

### Frontend exits / 502 from nginx

`BACKEND`, `SOCKETIO` and `FRAPPE_SITE_NAME_HEADER` must be set (they are, in the
compose file). If the site was created under a different name than
`FRAPPE_SITE_NAME_HEADER`, the frontend cannot pick the site:

```bash
podman exec -it solrise-frontend env | grep -E 'BACKEND|SOCKETIO|FRAPPE_SITE'
podman exec -it solrise-backend bench --site erp.localhost show-config | head
```

Set `SITE_NAME` in `.env` to the exact site name. To serve several hostnames,
add them as separate sites and adjust `FRAPPE_SITE_NAME_HEADER`.

### Scheduler container logs `No such command 'schedule'`

Older Frappe releases use a different entry point:

```yaml
scheduler:
  command: ["bench", "scheduler"]
```

Change it in the relevant compose file and `up -d` again.

### `socketio` not connecting / realtime updates dead

```bash
podman logs --tail=100 <websocket-container>
```

Confirm `redis_socketio` is set in `sites/common_site_config.json` and that
`redis-queue` is up (socketio uses it for pub/sub).

### Disk filling up

```bash
podman system df
podman image prune -f
podman volume ls
```

Old `./backups` directories and dangling images are the usual culprits.
`BACKUP_RETENTION_DAYS` prunes the former.

---

## Production / Traefik

### Certificate not issued

1. DNS must resolve to the VPS: `dig +short erp.yourdomain.com`.
2. Port 80 must be open at **both** the provider firewall and ufw:
   `sudo ufw status` and the Hostinger hPanel firewall.
3. Cloudflare proxy must be off (grey cloud) during the HTTP-01 challenge.
4. Inspect Traefik: `podman logs --tail=100 <traefik-container>`; look for
   `acme` errors.

If you exhaust the ACME rate limit, wait it out - do not repeatedly recreate
Traefik. Use the Let's Encrypt staging endpoint while debugging.

### `traefik` cannot find the containers

The Docker/Podman provider needs the socket. For rootless Podman:

```bash
systemctl --user enable --now podman.socket
echo "$XDG_RUNTIME_DIR/podman/podman.sock"
# .env: DOCKER_SOCK=/run/user/<uid>/podman/podman.sock
```

Confirm Traefik sees the router (requires the API to be enabled) or check that
the `frontend` labels show `traefik.enable=true`.

### 502 after recreating the frontend

Traefik caches provider state briefly. Wait ~10s, then re-request. If it
persists, confirm `frontend` is on the same network Traefik was told to use
(`--providers.docker.network=${COMPOSE_PROJECT_NAME}_net`).

### Bind to port 80/443 denied (rootless)

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
```

and make it persistent in `/etc/sysctl.d/99-solrise.conf`.

---

## Application

### `bench migrate` fails after an upgrade

Almost always a schema drift from a skipped release. Read the first traceback,
not the last. Practical recovery:

1. Restore the pre-upgrade backup (`./scripts/restore.sh`).
2. Bump **one** version step at a time (do not jump several majors).
3. If a custom app caused it, uninstall that app, migrate, then reinstall.

### Custom DocPerm change does not take effect

Permissions are cached:

```bash
podman exec -it solrise-backend bench --site erp.localhost clear-cache
```

and the user must re-login. Confirm the row exists:

```bash
podman exec -it solrise-backend bench --site erp.localhost mariadb \
  -e "select role,parent,read,write from \`tabCustom DocPerm\` where parent='Issue';"
```

### Scheduled jobs (reminders, SLA) never run

```bash
podman logs --tail=100 <scheduler-container>
podman exec -it solrise-backend bench --site erp.localhost scheduler status
podman exec -it solrise-backend bench --site erp.localhost enable-scheduler
```

Also confirm `ENABLE_SCHEDULER=true` in `.env` and that the create-site step ran
`enable-scheduler`.

### Emails not sending

Check the **Email Account** doctype, SMTP credentials, and that the outbound
port (587/465) is not blocked by the provider. Test:

```bash
podman exec -it solrise-backend bench --site erp.localhost sendmail --to you@example.com --subject test --content test
```

---

## Escalation checklist

When something is broken in production and the cause is unclear:

1. `SITE_ENV=prod make ps` - is anything crash-looping?
2. `SITE_ENV=prod make prod-logs` - read the first error, not the last.
3. `podman exec -it solrise-backend bench --site <site> doctor` - Frappe's own health check.
4. Recent change? Redeploy the previous image tag.
5. Migration-related? Restore the last backup, then investigate offline.
