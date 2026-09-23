import logging
import math
import time
from functools import wraps

import requests
from flask import g, jsonify, request, session, redirect, url_for

from function_api import NotAuthenticated, api_get

logger = logging.getLogger(__name__)

_API_PREFIX = '/api/ui'

_ACCESS_ERRORS = {
    401: ("session_expired", "Your session has expired. Please sign in again."),
    403: ("administrator_required", "This portal is for broker administrators. Your AVD access is unchanged."),
    503: ("authorization_unavailable", "Administrator access could not be verified. Please try again later."),
}


class PortalAccessError(Exception):
    """A fail-closed authentication, authorization, or capability-service error."""

    def __init__(self, status):
        self.status = status
        self.code, message = _ACCESS_ERRORS[status]
        super().__init__(message)


def portal_error_response(error):
    if error.status == 401:
        session.clear()
    return jsonify({"error": str(error), "code": error.code}), error.status


def _reject_session(reason):
    logger.info("Portal session rejected: %s", reason)
    session.clear()
    raise PortalAccessError(401)


def _nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def session_claims():
    """Require the MSAL-authenticated identity and an unexpired server-side token."""
    user = session.get("user")
    token = session.get("access_token")
    expiry = session.get("token_expiry")
    if (not isinstance(user, dict) or not _nonempty_string(user.get("tid"))
            or not _nonempty_string(user.get("oid")) or not _nonempty_string(token)):
        _reject_session("missing or invalid identity/token")

    try:
        valid_expiry = type(expiry) in (int, float) and math.isfinite(expiry) and expiry > time.time()
    except OverflowError:
        valid_expiry = False
    if not valid_expiry:
        _reject_session("missing, invalid, or expired token lifetime")
    return user


def portal_authority():
    """Read authority from the broker's validated API token, never ID-token roles.

    There is deliberately no cross-request capability cache or legacy fallback.
    A session/CSRF token alone must not authorize a management call.
    """
    claims = session_claims()
    try:
        payload = api_get('/me')
    except NotAuthenticated:
        _reject_session("missing API token")
    except requests.exceptions.HTTPError as error:
        status = getattr(error.response, 'status_code', None)
        logger.warning("Broker capability request rejected (HTTP %s).", status)
        if status == 401:
            _reject_session("API token rejected by the broker")
        raise PortalAccessError(403 if status == 403 else 503) from None
    except (requests.exceptions.RequestException, ValueError) as error:
        logger.warning("Broker capability request failed (%s).", type(error).__name__)
        raise PortalAccessError(503) from None

    subject = payload.get('subject') if isinstance(payload, dict) else None
    capabilities = payload.get('capabilities') if isinstance(payload, dict) else None
    if (not isinstance(subject, dict) or not _nonempty_string(subject.get('tenantId'))
            or not _nonempty_string(subject.get('objectId'))
            or not isinstance(capabilities, dict)
            or type(capabilities.get('manage')) is not bool
            or type(capabilities.get('connect')) is not bool):
        logger.warning("Broker capability response has an invalid shape.")
        raise PortalAccessError(503)

    if (subject['tenantId'].casefold() != claims['tid'].casefold()
            or subject['objectId'].casefold() != claims['oid'].casefold()):
        _reject_session("capability subject does not match the authenticated identity")

    # A slow capability response cannot extend the access token's lifetime.
    session_claims()
    return {
        "subject": {"tenantId": subject['tenantId'], "objectId": subject['objectId']},
        "capabilities": {"manage": capabilities['manage'], "connect": capabilities['connect']},
    }


def login_required(f):
    """Require live administrator authority before any BFF business operation."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        try:
            authority = portal_authority()
            if not authority['capabilities']['manage']:
                logger.info("Portal management request denied: administrator access required.")
                raise PortalAccessError(403)
        except PortalAccessError as error:
            if error.status == 401 and not request.path.startswith(_API_PREFIX):
                return redirect(url_for('login'))
            return portal_error_response(error)

        g.portal_authority = authority
        return f(*args, **kwargs)
    return decorated_function
