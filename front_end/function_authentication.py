import logging
from functools import wraps
from flask import session, redirect, url_for
from datetime import datetime

logger = logging.getLogger(__name__)

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        user = session.get("user")
        access_token = session.get("access_token")
        token_expiry = session.get("token_expiry")

        if not user or not access_token:
            logger.debug("User not authenticated, redirecting to login page.")
            return redirect(url_for('login'))

        if token_expiry:
            current_time = datetime.utcnow().timestamp()
            if current_time > token_expiry:
                logger.debug("Access token expired, redirecting to login page.")
                return redirect(url_for('login'))

        return f(*args, **kwargs)
    return decorated_function
