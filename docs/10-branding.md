# Branding and locale

**Goal:** end users see **Solrise** - not the upstream platform name - and the
system defaults to the **United States / USD**.

Applied by `solrise_erp.branding.ensure_branding()`, which is part of
`solrise_erp.install.apply_all()` and therefore runs on every install and every
`bench migrate`. Idempotent.

---

## 1. What is rebranded

| Where | Value | Effect |
|-------|-------|--------|
| `System Settings.app_name` | `Solrise` | browser/tab title, Desk brand |
| `Website Settings.app_name` | `Solrise` | website chrome |
| `Website Settings.brand_html` | Solrise lockup | login page brand |
| `Website Settings.copyright` | `Solrise` | footer |
| `Company` | `Solrise` | documents, print formats |
| `Global Defaults.country` | `United States` | locale |
| `Global Defaults.default_currency` | `USD` | accounting |
| `System Settings.currency` / `.country` | `USD` / `United States` | UI formatting |
| `System Settings.language` | `en` | UI language |
| `System Settings.time_zone` | `America/New_York` | timestamps |
| `hooks.py: app_title` | `Solrise ERP` | app listing in the Desk |
| `Workspace.title` / `.label` | `Solrise Settings`, `Solrise Integrations` | sidebar labels |
| Boot payload: `app_logo_url` | `/assets/solrise_erp/images/solrise-logo.svg` | navbar logo |
| Boot payload: `apps_data.apps[]` | title `Solrise ERP`, Solrise logo | app switcher |
| `templates/includes/footer/footer_powered.html` | `Powered by Solrise` | website/login footer |

`branding.py` writes the DocType values through `setup_helpers.set_single()`, so a
field that does not exist in a given version is skipped with a log line instead
of raising.

Some of the Desk payload is produced by the upstream app and attached *after* the
server-side `boot_session` hook has run, so two more mechanisms are needed:

- `boot.py` (`boot_session` hook) - rewrites the app title/logo and sidebar
  labels server-side.
- `public/js/solrise_erp.js` - a small boot patch that runs before the Desk
  renders and again on `app_ready`, enforcing the same replacements client-side.
  This is what actually removes the upstream name from the navbar, the app
  switcher and the sidebar.
- `templates/includes/footer/footer_powered.html` - an app-level template
  override. Because this app is loaded after the upstream apps, its copy of the
  template wins at render time and the footer credit links nowhere external.

> The sidebar workspaces are re-synced by the upstream app on every `bench
> migrate`, which would restore the original labels. `ensure_workspace_branding()`
> therefore runs from `after_migrate` (via `apply_all()`), so the rebrand is
> re-applied on the same migrate that would otherwise undo it. Verified to
> survive a full `bench migrate`.

---

## 2. Applying it

Automatic: `scripts/create-site.sh` installs the app, and `bench migrate` runs
`after_migrate` -> `apply_all()` -> `ensure_branding()`.

Manual re-apply on a running site:

```bash
podman exec -it solrise-backend bench --site <site> execute \
  solrise_erp.install.apply_all
```

Verify:

```bash
podman exec -it solrise-backend bench --site <site> execute \
  frappe.client.get_single_value --kwargs "{'doctype':'System Settings','fieldname':'app_name'}"
# -> Solrise
```

Or check the login page title in a browser - it should read **Solrise**.

---

## 3. Adding a real logo

`brand_html` ships as a text lockup so no image asset is required. To use a logo:

1. Upload it (Desk -> **File**, or drop it in `sites/<site>/public/files/`).
2. Ask for the URL, e.g. `/files/solrise-logo.png`.
3. Set it in **Website Settings -> Brand HTML**:

```html
<img src="/files/solrise-logo.png" alt="Solrise" style="height:32px">
```

4. Optionally set **App Logo**, **Favicon**, **Splash Image** and **Footer Logo**
   on the same form, then update `BRAND_HTML` in
   `apps/solrise_erp/solrise_erp/branding.py` so a fresh deployment gets it too.

---

## 4. What is deliberately NOT rebranded

Being explicit about this avoids surprise later:

- **The `erpnext` app itself.** It is installed as `erpnext`
  (`bench install-app erpnext`, `tabIssue`, `sites/apps.txt`). Renaming it means
  forking the upstream app and is not worth it - none of it is user-facing.
- **A few upstream strings inside the Desk**, such as the Help/About menu. Those
  live in the upstream source, not in configuration. They are not shown on the
  login page or on business documents.
- **Translations.**
- **Module identifiers** (`Module Def`, `allow_modules`, `module_wise_workspaces`)
  such as `ERPNext Integrations`. These are permission keys used to filter the
  sidebar. Renaming them in the payload without renaming the `Module Def` would
  hide workspaces, so they are left alone; they surface only in the module
  filter and Developer tools, never on the sidebar or a business document.
- **Source-level references** - `erpnext` as an app name, table prefixes and
  version numbers.
- **Licence and copyright notices.** See below.

Internally the docs and install records still name `erpnext 15.121.2` where that
is a version fact rather than branding.

---

## 5. Licensing

Both Frappe Framework and ERPNext are **MIT licensed**. Rebranding the
presentation is permitted; removing the copyright notices is not.

- Keep the `license.txt` / `LICENSE` files in `apps/erpnext`, `apps/frappe` and
  `apps/hrms` intact.
- Keep the licence text in the image - it is attribution for the software you
  build on.
- This repository's own `apps/solrise_erp/license.txt` is MIT as well.

If you distribute the product commercially, have counsel confirm the notice
requirements; nothing here removes them.
