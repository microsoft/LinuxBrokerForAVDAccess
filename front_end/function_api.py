"""Helpers for calling the broker API on behalf of the signed-in user.

Centralises the bearer-token header, request timeouts and JSON decoding so the
individual route modules do not each rebuild them.
"""

import logging

import requests
from flask import session
from datetime import datetime

from config import API_URL

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT = 15


class NotAuthenticated(Exception):
    """Raised when there is no usable access token in the session."""


def auth_headers():
    """Return the Authorization header for the current session."""
    access_token = session.get("access_token")
    if not access_token:
        raise NotAuthenticated("No access token in session")
    return {"Authorization": "Bearer " + access_token}


def api_get(path, timeout=DEFAULT_TIMEOUT):
    response = requests.get(f"{API_URL}{path}", headers=auth_headers(), timeout=timeout)
    response.raise_for_status()
    return response.json()


def api_post(path, payload=None, params=None, timeout=DEFAULT_TIMEOUT):
    response = requests.post(
        f"{API_URL}{path}", headers=auth_headers(), json=payload,
        params=params, timeout=timeout
    )
    response.raise_for_status()
    return response.json()


TRUTHY = {"1", "true", "yes", "on"}


def filters_from_args(args):
    """Build the history filter dict from query-string arguments.

    Filters live in the URL rather than the Flask session, so they are
    bookmarkable and two browser tabs cannot overwrite each other's criteria.
    """
    def flag(name):
        return str(args.get(name, "")).strip().lower() in TRUTHY

    return {
        "startdate": (args.get("startdate") or "").strip(),
        "enddate": (args.get("enddate") or "").strip(),
        "limit": (args.get("limit") or "").strip(),
        "ignore_dates": flag("ignore_dates"),
        "ignore_limit": flag("ignore_limit"),
    }


def validate_history_filters(filters):
    """Return a human-readable error for an unusable filter set, else None.

    Reported against the request that carried the bad value so the operator sees
    it on the form they are looking at, rather than as a later query failure.
    """
    if filters.get("ignore_dates"):
        return None

    for label, key in (("start", "startdate"), ("end", "enddate")):
        value = (filters.get(key) or "").strip()
        if not value:
            continue
        try:
            datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            return f"Invalid {label} date format. Please use 'YYYY-MM-DD'."

    return None


def pagination_from_args(args, default_per_page=10, max_per_page=200):
    """Clamp page and per_page so a hand-edited query string cannot break a page."""
    try:
        page = max(1, int(args.get("page", 1)))
    except (TypeError, ValueError):
        page = 1

    try:
        per_page = min(max_per_page, max(1, int(args.get("per_page", default_per_page))))
    except (TypeError, ValueError):
        per_page = default_per_page

    return page, per_page


def build_history_payload(filters):
    """Translate the filter bar values into the API's request body.

    The operator enters YYYY-MM-DD; the stored procedures expect MM/DD/YYYY. The
    ignore flags win over whatever is in the date and limit boxes.
    """
    filters = filters or {}
    payload = {}

    if not filters.get("ignore_dates"):
        for key in ("startdate", "enddate"):
            raw = (filters.get(key) or "").strip()
            if not raw:
                continue
            try:
                payload[key] = datetime.strptime(raw, "%Y-%m-%d").strftime("%m/%d/%Y")
            except ValueError:
                # Validated on submit; skip rather than send something unparseable.
                logger.warning("Ignoring unparseable %s filter value %r", key, raw)

    if not filters.get("ignore_limit"):
        raw_limit = str(filters.get("limit") or "").strip()
        if raw_limit:
            try:
                payload["limit"] = int(raw_limit)
            except ValueError:
                logger.warning("Ignoring unparseable limit filter value %r", raw_limit)

    return payload


def fetch_history_page(path, filters, page, per_page):
    """Fetch one page from a history endpoint.

    Returns (rows, total_items, total_pages). Falls back to slicing client-side when
    the API predates pagination and still answers with a bare list, so the portal
    keeps working if it is deployed ahead of the API.
    """
    payload = build_history_payload(filters)
    result = api_post(path, payload, params={"page": page, "per_page": per_page})

    if isinstance(result, dict) and "items" in result:
        total = int(result.get("total") or 0)
        total_pages = int(result.get("total_pages") or 0)
        return result.get("items") or [], total, total_pages

    # Older API: a bare array (or the legacy {"message": ...} empty envelope).
    rows = result if isinstance(result, list) else []
    total = len(rows)
    total_pages = (total + per_page - 1) // per_page if per_page else 0
    start = (page - 1) * per_page
    return rows[start:start + per_page], total, total_pages


# Values are constrained by the VmStatus CHECK constraint in
# sql_queries/003_create_table-virtual_machines.sql.
VM_STATUSES = ("Available", "CheckedOut", "Maintenance", "Released")


def _build_stats(total, available, checked_out, maintenance, released,
                 unreachable, powered_on, ready):
    """Shape the dashboard counters from raw counts."""
    other = max(0, total - available - checked_out - maintenance - released)

    return {
        "total": total,
        "available": available,
        "checked_out": checked_out,
        "maintenance": maintenance,
        "released": released,
        "other": other,
        "unreachable": unreachable,
        "powered_on": powered_on,
        "powered_off": max(0, total - powered_on),
        "ready": ready,
        "attention": maintenance + unreachable,
        "utilization": round((checked_out / total) * 100) if total else 0,
        "pct": {
            key: (round((value / total) * 100, 2) if total else 0)
            for key, value in (
                ("available", available),
                ("checked_out", checked_out),
                ("released", released),
                ("maintenance", maintenance),
                ("other", other),
            )
        },
    }


def summary_from_api(payload):
    """Map the /vms/summary response onto the dashboard's counters."""
    payload = payload or {}

    def count(key):
        try:
            return int(payload.get(key) or 0)
        except (TypeError, ValueError):
            return 0

    return _build_stats(
        total=count("TotalVMs"),
        available=count("Available"),
        checked_out=count("CheckedOut"),
        maintenance=count("Maintenance"),
        released=count("Released"),
        unreachable=count("Unreachable"),
        powered_on=count("PoweredOn"),
        ready=count("Ready"),
    )


def fetch_vm_summary():
    """Fetch dashboard counters, preferring the aggregate endpoint.

    Falls back to counting the full VM list client-side if /vms/summary does not
    behave, so the portal keeps working when it is deployed ahead of the API.

    The fallback deliberately triggers on any HTTP error, not just 404. An API build
    that predates this endpoint does not 404: Werkzeug matches /api/vms/summary
    against the older `/api/vms/<vmid>` rule, so it reaches GetVmDetails with
    @VMID = 'summary', fails the int conversion in SQL, and returns 500. Keying the
    fallback on 404 would therefore never fire against the very build it exists for.

    This cannot mask a real outage: if the broker or database is genuinely down, the
    /vms fallback fails too and the caller still sees the error.
    """
    try:
        return summary_from_api(api_get('/vms/summary'))
    except requests.exceptions.HTTPError as e:
        status = getattr(e.response, 'status_code', None)
        logger.info("Falling back to client-side VM counting (/vms/summary returned %s).", status)
        return summarize_vms(api_get('/vms'))


def summarize_vms(vms):
    """Aggregate a VM list into the counters shown on the dashboard."""
    vms = vms or []

    def count(field, value):
        return sum(1 for vm in vms if (vm or {}).get(field) == value)

    total = len(vms)
    available = count("VmStatus", "Available")
    checked_out = count("VmStatus", "CheckedOut")
    maintenance = count("VmStatus", "Maintenance")
    released = count("VmStatus", "Released")
    unreachable = count("NetworkStatus", "Unreachable")
    powered_on = count("PowerState", "On")

    # A VM is "ready" only when it is powered on, reachable and unassigned --
    # the same condition the API uses to pick a host for checkout.
    ready = sum(
        1
        for vm in vms
        if (vm or {}).get("VmStatus") == "Available"
        and (vm or {}).get("PowerState") == "On"
        and (vm or {}).get("NetworkStatus") == "Reachable"
    )

    return _build_stats(
        total=total,
        available=available,
        checked_out=checked_out,
        maintenance=maintenance,
        released=released,
        unreachable=unreachable,
        powered_on=powered_on,
        ready=ready,
    )
