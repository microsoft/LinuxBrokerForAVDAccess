"""Shared helpers for the JSON endpoints the React portal calls.

The portal is a single-page app, so these routes replace what the Jinja views used
to do: they return data instead of HTML, and they turn broker failures into a
predictable JSON error envelope rather than a flash message and a redirect.
"""

import logging
from functools import wraps

import requests
from flask import jsonify, request

from function_api import (
    NotAuthenticated,
    fetch_history_page,
    filters_from_args,
    pagination_from_args,
    validate_history_filters,
)
from function_authentication import PortalAccessError, portal_error_response

logger = logging.getLogger(__name__)

# Every JSON endpoint lives under this prefix. Anything outside it is either a
# server-side auth redirect or a path that serves the SPA shell.
API_PREFIX = '/api/ui'


class BadRequest(Exception):
    """Raised when the client sent something unusable. Becomes a 400."""


def json_body():
    """The request's JSON object, or an empty dict for a missing or non-object body."""
    payload = request.get_json(silent=True)
    return payload if isinstance(payload, dict) else {}


def require(payload, *names):
    """Return the named values, rejecting the request if any are blank.

    The Jinja forms relied on `request.form['x']` raising, which surfaced as a
    bare 400. Naming the field is far more useful to whoever is debugging.
    """
    missing = [name for name in names
               if payload.get(name) is None or str(payload.get(name)).strip() == '']
    if missing:
        raise BadRequest(f"Missing required field(s): {', '.join(missing)}.")
    return [payload[name] for name in names]


def json_error(message, status=502, **extra):
    return jsonify({"error": message, **extra}), status


def upstream_error_message(response, fallback):
    """Prefer the broker's own explanation, which names the rejected value."""
    if response is None:
        return fallback
    try:
        payload = response.json()
    except ValueError:
        return fallback
    if isinstance(payload, dict):
        message = payload.get("error") or payload.get("message")
        return message if isinstance(message, str) and message else fallback
    return fallback


def broker_endpoint(error_message, conflict_message=None):
    """Turn broker exceptions into JSON responses instead of flash-and-redirect.

    A 401/403 uses the safe portal access error so the SPA can clear its data and
    show sign-in or denial. Other 4xx errors keep their actionable status; anything
    else becomes a 502, because the failure is between the portal and the broker
    rather than a problem with the operator's request.
    """
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            try:
                return view(*args, **kwargs)
            except BadRequest as e:
                return json_error(str(e), 400)
            except NotAuthenticated:
                return portal_error_response(PortalAccessError(401))
            except requests.exceptions.HTTPError as e:
                response = getattr(e, 'response', None)
                status = getattr(response, 'status_code', None) or 502
                logger.error("%s (HTTP %s).", error_message, status)
                if status in (401, 403):
                    return portal_error_response(PortalAccessError(status))
                if status == 409 and conflict_message:
                    return json_error(conflict_message, 409)
                if 400 <= status < 500:
                    return json_error(upstream_error_message(response, error_message), status)
                return json_error(error_message, 502)
            except (requests.exceptions.RequestException, ValueError) as e:
                logger.error("%s: %s", error_message, e)
                return json_error(error_message, 502)

        return wrapper

    return decorator


def history_response(rows, page, per_page, total_items, total_pages):
    """The paged envelope every history endpoint returns."""
    return jsonify({
        "items": rows,
        "page": page,
        "perPage": per_page,
        "total": total_items,
        "totalPages": total_pages,
    })


def history_page(path):
    """Fetch one page of a history endpoint using the filters in the query string.

    Shared by VM history, the scaling activity log and scaling rule history, which
    only differ by the broker path they read from.
    """
    filters = filters_from_args(request.args)

    error = validate_history_filters(filters)
    if error:
        raise BadRequest(error)

    page, per_page = pagination_from_args(request.args)
    rows, total_items, total_pages = fetch_history_page(path, filters, page, per_page)

    return history_response(rows, page, per_page, total_items, total_pages)
