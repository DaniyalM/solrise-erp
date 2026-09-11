"""
Solrise ERP - custom roles and DocType-level RBAC (Stage 2.2).

Creates the Solrise roles and grants Custom DocPerms. Custom DocPerms are used
(not the standard DocPerm) so the grants are portable fixtures and never
conflict with the platform's own permission matrix.

Run inside the backend container:
    ./scripts/run-python.sh scripts/roles_rbac.py
"""
import os

import frappe

SITE = os.environ.get("SITE_NAME", "erp.localhost")

# DocPerm boolean fields we normalise on every grant.
PERM_FIELDS = (
    "read", "write", "create", "delete", "submit", "cancel", "amend",
    "report", "export", "import", "share", "print", "email", "if_owner",
)

# ================================ EDIT HERE ==================================
ROLES = [
    # (role_name, desk_access)
    ("Support Agent", 1),
    ("Support Manager", 1),
    ("CRM User", 1),
    ("CRM Manager", 1),
    ("Finance Approver", 1),
    ("Solrise Admin", 1),
]

# role -> [(doctype, permlevel, {perm flags})]
GRANTS = {
    "Support Agent": [
        ("Issue", 0, {"read": 1, "write": 1, "create": 1, "email": 1, "report": 1}),
        ("Issue", 1, {"read": 1, "write": 1, "if_owner": 1}),  # own docs only
        ("Service Level Agreement", 0, {"read": 1}),
    ],
    "Support Manager": [
        ("Issue", 0, {"read": 1, "write": 1, "create": 1, "delete": 1,
                      "email": 1, "report": 1, "export": 1, "share": 1}),
        ("Service Level Agreement", 0, {"read": 1, "write": 1, "create": 1}),
        ("Assignment Rule", 0, {"read": 1, "write": 1, "create": 1}),
    ],
    "CRM User": [
        ("Lead", 0, {"read": 1, "write": 1, "create": 1, "report": 1, "email": 1}),
        ("Opportunity", 0, {"read": 1, "write": 1, "create": 1, "report": 1}),
        ("Quotation", 0, {"read": 1, "write": 1, "create": 1}),
        ("Contact", 0, {"read": 1, "write": 1, "create": 1}),
    ],
    "CRM Manager": [
        ("Lead", 0, {"read": 1, "write": 1, "create": 1, "delete": 1,
                     "report": 1, "export": 1, "share": 1}),
        ("Opportunity", 0, {"read": 1, "write": 1, "create": 1, "delete": 1,
                            "report": 1, "export": 1}),
        ("Quotation", 0, {"read": 1, "write": 1, "create": 1, "submit": 1,
                          "cancel": 1, "amend": 1}),
        ("Contact", 0, {"read": 1, "write": 1, "create": 1, "delete": 1}),
    ],
    "Finance Approver": [
        ("Payment Entry", 0, {"read": 1, "write": 1, "submit": 1, "report": 1}),
        ("Purchase Order", 0, {"read": 1, "submit": 1}),
        ("Sales Invoice", 0, {"read": 1, "submit": 1}),
    ],
    "Solrise Admin": [],  # role exists for workflow step assignment; perms via System Manager
}
# =============================================================================


def _bootstrap():
    if not getattr(frappe.local, "site", None):
        frappe.init(site=SITE, sites_path="/home/frappe/frappe-bench/sites")
        frappe.connect()
    frappe.set_user("Administrator")


def ensure_role(role_name, desk_access=1):
    if frappe.db.exists("Role", role_name):
        print("  = Role exists: %s" % role_name)
        return
    frappe.get_doc({
        "doctype": "Role",
        "role_name": role_name,
        "desk_access": desk_access,
        "disabled": 0,
    }).insert(ignore_permissions=True)
    frappe.db.commit()
    print("  + Role created: %s" % role_name)


def grant(role, doctype, permlevel=0, **perms):
    if not frappe.db.exists("DocType", doctype):
        print("  ! %s not installed; skipping grant for %s" % (doctype, role))
        return
    flags = {field: 0 for field in PERM_FIELDS}
    flags.update(perms)

    existing = frappe.db.get_value(
        "Custom DocPerm",
        {"parent": doctype, "role": role, "permlevel": permlevel},
        "name",
    )
    if existing:
        doc = frappe.get_doc("Custom DocPerm", existing)
        doc.update(flags)
        doc.save(ignore_permissions=True)
        action = "updated"
    else:
        payload = {
            "doctype": "Custom DocPerm",
            "parent": doctype,
            "parenttype": "DocType",
            "parentfield": "permissions",
            "role": role,
            "permlevel": permlevel,
        }
        payload.update(flags)
        doc = frappe.get_doc(payload)
        doc.insert(ignore_permissions=True)
        action = "granted"

    # Custom DocPerm changes only take effect after the doctype cache is cleared.
    frappe.clear_cache(doctype=doctype)
    print("  + %s %s on %s (permlevel %s)" % (action, role, doctype, permlevel))


def main():
    _bootstrap()
    print("Configuring roles for site: %s\n" % SITE)

    print("Roles")
    for role_name, desk_access in ROLES:
        try:
            ensure_role(role_name, desk_access)
        except Exception as exc:
            frappe.db.rollback()
            print("  ! Role %s failed: %s" % (role_name, exc))

    print("\nPermissions")
    for role_name, grants in GRANTS.items():
        for doctype, permlevel, perms in grants:
            try:
                grant(role_name, doctype, permlevel, **perms)
            except Exception as exc:
                frappe.db.rollback()
                print("  ! grant %s/%s failed: %s" % (role_name, doctype, exc))

    frappe.db.commit()
    print("\nroles_rbac.py complete.")
    print("Export the result so it survives redeployment:")
    print("  ./scripts/export-fixtures.sh && ./scripts/pull-fixtures.sh")


if __name__ == "__main__":
    main()
    frappe.destroy()
