import logging
from functools import wraps
from flask import jsonify, request, session, redirect, url_for
from datetime import datetime

logger = logging.getLogger(__name__)

# Kept in step with function_bff.API_PREFIX. Importing it here would be circular,
# so the prefix is compared directly.
_API_PREFIX = '/api/ui'


def _unauthenticated_response(reason):
    """A page request goes to the sign-in redirect; a fetch gets JSON.

    The React portal cannot follow a 302 to Entra ID from `fetch`, so an expired
    session has to come back as a 401 it can act on by navigating to /login.
    """
    logger.debug("%s", reason)

    if request.path.startswith(_API_PREFIX):
        return jsonify({"error": "Your session has expired. Please sign in again."}), 401

    return redirect(url_for('login'))


def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        user = session.get("user")
        access_token = session.get("access_token")
        token_expiry = session.get("token_expiry")

        if not user or not access_token:
            return _unauthenticated_response("User not authenticated, redirecting to login page.")

        if token_expiry:
            current_time = datetime.utcnow().timestamp()
            if current_time > token_expiry:
                return _unauthenticated_response("Access token expired, redirecting to login page.")

        return f(*args, **kwargs)
    return decorated_function
