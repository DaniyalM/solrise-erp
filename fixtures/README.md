# Fixtures

Durable, versioned application configuration. Everything here is re-imported
automatically by Frappe during `bench migrate` whenever the owning app is
installed (see `docs/02-phase2-module-config.md`).

## Layout

```
fixtures/
└── <app>/
    └── fixtures/
        ├── custom_field.json
        ├── property_setter.json
        ├── custom_doc_perms.json
        ├── role.json
        ├── workflow.json
        └── notification.json
```

## Producing fixtures

```bash
make image                 # ensure the running image matches the source
make local-up
./scripts/run-python.sh scripts/setup_erp.py    # apply config
./scripts/run-python.sh scripts/roles_rbac.py
make fixtures              # bench export-fixtures inside the container
./scripts/pull-fixtures.sh # tar the JSON out into this directory
git add fixtures && git commit -m "chore: refresh fixtures"
```

## Why this directory is committed

App sources live inside the container image, not in a volume. Anything exported
into the container is therefore destroyed on the next `make image`. This
directory is the only durable home for customisations - commit it.

## Applying on a new deployment

Automatic: the app declares a `fixtures` list in its `hooks.py`, and
`bench install-app` -> `bench migrate` -> `sync_fixtures()` writes these
records into the new database.

Manual re-sync on a running site:

```bash
podman exec -it solrise-backend bench --site erp.localhost migrate
```
