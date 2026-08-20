"""Helpers for calling the broker API on behalf of the signed-in user.

Centralises the bearer-token header, request timeouts and JSON decoding so the
individual route modules do not each rebuild them.
"""

import logging

import requests
from flask import session

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


def api_post(path, payload=None, timeout=DEFAULT_TIMEOUT):
    response = requests.post(
        f"{API_URL}{path}", headers=auth_headers(), json=payload, timeout=timeout
    )
    response.raise_for_status()
    return response.json()


# Values are constrained by the VmStatus CHECK constraint in
# sql_queries/003_create_table-virtual_machines.sql.
VM_STATUSES = ("Available", "CheckedOut", "Maintenance", "Released")


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
        "powered_off": total - powered_on,
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
