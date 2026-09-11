"""
Solrise ERP - programmatic module configuration (Stage 2.1).

Configures HR/HRMS, Selling/Buying, CRM and Service Desk settings, leave
types, SLAs and assignment rules without touching the UI.

Run inside the backend container:
    ./scripts/run-python.sh scripts/setup_erp.py

Safe to re-run: values are updated in place and records are created only once.

Field names are guarded by frappe.get_meta(...).has_field(), so if a field
moved between the platform/HRMS point releases the script logs a "skip" instead of
crashing. Adjust the constants below to match your policy.
"""
import os

import frappe

SITE = os.environ.get("SITE_NAME", "erp.localhost")

# ================================ EDIT HERE ==================================
# Single DocType settings. Anything not present in your installed version is
# skipped with a log line.
HR_SETTINGS = {
    # "Employee ID" or "Naming Series"
    "emp_created_by": "Naming Series",
    "leave_approver_mandatory_in_leave_application": 1,
    "expense_approver_mandatory_in_expense_claim": 1,
}
SELLING_SETTINGS = {
    "cust_master_name": "Customer Name",
    "so_required": "No",
    "dn_required": "No",
}
BUYING_SETTINGS = {
    "po_required": "No",
    "pr_required": "No",
    "maintain_same_rate": 1,
}
CRM_SETTINGS = {
    # Kept minimal and guarded; extend to taste.
    "close_opportunity_after_days": 30,
}
SUPPORT_SETTINGS = {
    # SLA creation is refused unless this is on (Support Settings.validate).
    "track_service_level_agreement": 1,
    "allow_resetting_service_level_agreement": 1,
    "close_issue_after_days": 7,
}

# Gender ships empty in this build; Employee creation fails without it.
GENDERS = ["Male", "Female", "Other", "Prefer not to say"]

LEAVE_TYPES = [
    {"leave_type_name": "Casual Leave", "max_days_allowed": 12, "is_lwp": 0, "is_encashable": 0},
    {"leave_type_name": "Sick Leave",   "max_days_allowed": 10, "is_lwp": 0, "is_encashable": 0},
    {"leave_type_name": "Earned Leave", "max_days_allowed": 18, "is_lwp": 0, "is_encashable": 1},
]

# Issue.priority is a LINK to Issue Priority; the table ships empty in this
# build, so seed it before anything tries to set an Issue priority.
ISSUE_PRIORITIES = ["Low", "Medium", "High", "Urgent"]

# Service Level Agreement in v15:
#   autoname is "SLA-{document_type}-{service_level}" (there is no
#   service_level_agreement field), entity_type accepts only
#   Customer / Customer Group / Territory, and the child table is
#   "Service Level Priority" whose response_time/resolution_time are Duration
#   fields - i.e. SECONDS, not hours.
SLA_DOCUMENT_TYPE = "Issue"
SLA_SERVICE_LEVEL = "Standard"
# The SLA is refused without a holiday list and a working-hours child table.
HOLIDAY_LIST_NAME = "Solrise Default Holidays"
SLA_WORKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
SLA_START_TIME = "09:00:00"
SLA_END_TIME = "18:00:00"
SLA_FULFILLED_ON = ["Resolved", "Closed"]
SLA_PRIORITIES = [
    {"priority": "Urgent", "response_time": 1800,  "resolution_time": 14400},
    {"priority": "High",   "response_time": 3600,  "resolution_time": 28800},
    {"priority": "Medium", "response_time": 14400, "resolution_time": 86400, "default_priority": 1},
    {"priority": "Low",    "response_time": 28800, "resolution_time": 172800},
]

ASSIGNMENT_RULE_NAME = "Solrise Support Routing"
# =============================================================================


def _bootstrap():
    """Make the file runnable both via `bench console` and plain python."""
    if not getattr(frappe.local, "site", None):
        frappe.init(site=SITE, sites_path="/home/frappe/frappe-bench/sites")
        frappe.connect()
    frappe.set_user("Administrator")


def set_single(doctype, values):
    try:
        doc = frappe.get_doc(doctype)
    except Exception as exc:  # DocType not installed in this version
        print("  ! %s unavailable (%s)" % (doctype, exc))
        return
    meta = frappe.get_meta(doctype)
    changed, skipped = [], []
    for field, value in values.items():
        if meta.has_field(field):
            doc.set(field, value)
            changed.append(field)
        else:
            skipped.append(field)
    if changed:
        doc.save(ignore_permissions=True)
        frappe.db.commit()
    print("  + %s: set %s%s" % (
        doctype,
        ", ".join(changed) or "nothing",
        (" (skipped %s)" % ", ".join(skipped)) if skipped else "",
    ))


def ensure_doc(doctype, filters, values, child_tables=None):
    try:
        name = frappe.db.get_value(doctype, filters)
    except Exception as exc:
        print("  ! %s unavailable (%s)" % (doctype, exc))
        return None
    if name:
        print("  = %s exists: %s" % (doctype, name))
        return frappe.get_doc(doctype, name)

    payload = {"doctype": doctype}
    payload.update(values or {})
    if child_tables:
        payload.update(child_tables)
    try:
        doc = frappe.get_doc(payload)
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
        print("  + %s created: %s" % (doctype, doc.name))
        return doc
    except Exception as exc:
        frappe.db.rollback()
        print("  ! could not create %s %s: %s" % (doctype, filters, exc))
        return None


def ensure_genders():
    if not frappe.db.exists("DocType", "Gender"):
        return
    created = []
    for gender in GENDERS:
        if frappe.db.exists("Gender", gender):
            continue
        frappe.get_doc({"doctype": "Gender", "gender": gender}).insert(ignore_permissions=True)
        created.append(gender)
    frappe.db.commit()
    print("  = Gender: created %s" % (", ".join(created) or "none"))


def configure_hr():
    print("HR / HRMS")
    set_single("HR Settings", HR_SETTINGS)
    ensure_genders()
    for lt in LEAVE_TYPES:
        name = lt["leave_type_name"]
        doc = ensure_doc("Leave Type", {"leave_type_name": name}, lt)
        if doc:
            for field, value in lt.items():
                if field != "leave_type_name":
                    doc.set(field, value)
            doc.save(ignore_permissions=True)
    frappe.db.commit()


def configure_sales_and_buying():
    print("Selling / Buying / CRM")
    set_single("Selling Settings", SELLING_SETTINGS)
    set_single("Buying Settings", BUYING_SETTINGS)
    set_single("CRM Settings", CRM_SETTINGS)


def ensure_issue_priorities():
    """Create the Issue Priority records the Link fields depend on."""
    meta = frappe.get_meta("Issue Priority")
    created = []
    for name in ISSUE_PRIORITIES:
        if frappe.db.exists("Issue Priority", name):
            continue
        doc = frappe.new_doc("Issue Priority")
        doc.name = name
        # Issue Priority autonames on "Prompt"; suppress the interactive prompt.
        doc.flags.name_set = True
        if meta.has_field("description"):
            doc.description = "%s priority" % name
        doc.insert(ignore_permissions=True)
        created.append(name)
    frappe.db.commit()
    print("  = Issue Priority: created %s" % (", ".join(created) or "none"))


def ensure_holiday_list():
    """The SLA and HR documents both need a Holiday List.

    the platform resolves it per employee via Company.default_holiday_list (falling
    back to Global Defaults). Without that, submitting a Leave Application dies
    with "Please set a default Holiday List for Employee ... or Company ...".
    """
    if frappe.db.exists("Holiday List", HOLIDAY_LIST_NAME):
        name = HOLIDAY_LIST_NAME
        print("  = Holiday List exists: %s" % name)
    else:
        doc = frappe.get_doc({
            "doctype": "Holiday List",
            "holiday_list_name": HOLIDAY_LIST_NAME,
            "from_date": frappe.utils.today(),
            "to_date": frappe.utils.add_days(frappe.utils.today(), 365),
        })
        doc.insert(ignore_permissions=True)
        name = doc.name
        print("  + Holiday List created: %s" % name)

    # Point the company (and the global default) at it so HR can resolve it.
    company = (frappe.db.get_single_value("Global Defaults", "default_company")
               or frappe.db.get_value("Company", {}, "name"))
    if company and frappe.get_meta("Company").has_field("default_holiday_list"):
        if not frappe.db.get_value("Company", company, "default_holiday_list"):
            frappe.db.set_value("Company", company, "default_holiday_list", name,
                                update_modified=False)
            print("  + Company default holiday list set: %s -> %s" % (company, name))
    frappe.db.commit()
    return name


def ensure_sla():
    """Create or refresh the default Issue SLA."""
    filters = {"document_type": SLA_DOCUMENT_TYPE, "service_level": SLA_SERVICE_LEVEL}
    rows = [dict(row) for row in SLA_PRIORITIES
            if frappe.db.exists("Issue Priority", row["priority"])]
    values = {
        "document_type": SLA_DOCUMENT_TYPE,
        "service_level": SLA_SERVICE_LEVEL,
        "enabled": 1,
        "default_service_level_agreement": 1,
        "apply_sla_for_resolution": 1,
        "start_date": frappe.utils.today(),
        "holiday_list": ensure_holiday_list(),
    }
    if frappe.db.exists("Issue Priority", "Medium"):
        values["default_priority"] = "Medium"

    fulfilled_on = [{"status": status} for status in SLA_FULFILLED_ON]
    working_hours = [
        {"workday": day, "start_time": SLA_START_TIME, "end_time": SLA_END_TIME}
        for day in SLA_WORKDAYS
    ]

    existing = frappe.db.get_value("Service Level Agreement", filters)
    if existing:
        doc = frappe.get_doc("Service Level Agreement", existing)
        for field, value in values.items():
            doc.set(field, value)
        doc.set("priorities", [])
        for row in rows:
            doc.append("priorities", row)
        doc.set("sla_fulfilled_on", [])
        for row in fulfilled_on:
            doc.append("sla_fulfilled_on", row)
        doc.set("support_and_resolution", [])
        for row in working_hours:
            doc.append("support_and_resolution", row)
        doc.save(ignore_permissions=True)
        print("  = Service Level Agreement updated: %s" % doc.name)
    else:
        doc = frappe.get_doc(dict(values, doctype="Service Level Agreement"))
        for row in rows:
            doc.append("priorities", row)
        for row in fulfilled_on:
            doc.append("sla_fulfilled_on", row)
        for row in working_hours:
            doc.append("support_and_resolution", row)
        doc.insert(ignore_permissions=True)
        print("  + Service Level Agreement created: %s" % doc.name)
    frappe.db.commit()


def ensure_assignment_rule():
    if frappe.db.exists("Assignment Rule", ASSIGNMENT_RULE_NAME):
        print("  = Assignment Rule exists: %s" % ASSIGNMENT_RULE_NAME)
        return
    ensure_doc(
        "Assignment Rule",
        {"name": ASSIGNMENT_RULE_NAME},
        {
            "name": ASSIGNMENT_RULE_NAME,
            "document_type": "Issue",
            "assign_condition": "status == 'Open'",
            "unassign_condition": "status in ('Resolved', 'Closed')",
            "close_condition": "status == 'Closed'",
            "rule": "Round Robin",
            "disabled": 0,
        },
        {
            "users": [{"user": "Administrator"}],
            "assignment_days": [{"day": d} for d in
                                ("Monday", "Tuesday", "Wednesday",
                                 "Thursday", "Friday")],
        },
    )


def configure_support():
    print("Support / Service Desk")
    set_single("Support Settings", SUPPORT_SETTINGS)
    ensure_issue_priorities()
    ensure_sla()
    ensure_assignment_rule()


def main():
    _bootstrap()
    print("Configuring site: %s\n" % SITE)
    for section in (configure_hr, configure_sales_and_buying, configure_support):
        try:
            section()
        except Exception as exc:
            frappe.db.rollback()
            print("  ! section %s failed: %s" % (section.__name__, exc))
        print("")
    frappe.db.commit()
    frappe.clear_cache()
    print("setup_erp.py complete.")


if __name__ == "__main__":
    main()
    frappe.destroy()
