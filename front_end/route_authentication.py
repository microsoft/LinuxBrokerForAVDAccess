import logging

from msal import ConfidentialClientApplication
from flask import request, redirect, url_for, session
from datetime import datetime, timedelta
from config import CLIENT_ID, TENANT_ID, CLIENT_SECRET, AUTHORITY, API_SCOPE

logger = logging.getLogger(__name__)

def register_route_authentication(app):
    @app.route('/login')
    def login():
        try:
            msal_app = ConfidentialClientApplication(
                CLIENT_ID, authority=AUTHORITY, client_credential=CLIENT_SECRET
            )

            auth_url = msal_app.get_authorization_request_url(
                scopes=API_SCOPE,
                redirect_uri=url_for('authorized', _external=True, _scheme='https')
            )

            return redirect(auth_url), 302
        except Exception as e:
            logger.error("An error occurred during login: %s", e)
            return "An error occurred during login.", 500

    @app.route('/getAToken')
    def authorized():
        try:
            msal_app = ConfidentialClientApplication(
                CLIENT_ID, authority=AUTHORITY, client_credential=CLIENT_SECRET
            )

            code = request.args.get('code')

            if not code:
                logger.error("Authorization code not found")
                return "Authorization code not found", 400

            result = msal_app.acquire_token_by_authorization_code(
                code=code,
                scopes=API_SCOPE,
                redirect_uri=url_for('authorized', _external=True, _scheme='https')
            )

            if "error" in result:
                error_description = result.get("error_description", result.get("error"))
                logger.error("Login failure: %s", error_description)

                if result.get("error") == "invalid_grant":
                    return "Invalid authorization code.", 400
                else:
                    return f"Login failure: {error_description}", 401

            session["user"] = result.get("id_token_claims")
            session["access_token"] = result.get("access_token")

            # Store token expiration time
            expires_in = result.get("expires_in")  # in seconds
            session["token_expiry"] = (datetime.utcnow() + timedelta(seconds=expires_in)).timestamp()

            return redirect(url_for('index', _external=True, _scheme='https')), 302
        except Exception as e:
            logger.error("An error occurred during authorization process: %s", e)
            return "An error occurred during authorization.", 500

    @app.route('/logout')
    def logout():
        try:
            session.clear()

            logout_url = (
                f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/logout"
                f"?post_logout_redirect_uri={url_for('index', _external=True)}"
            )

            return redirect(logout_url), 302
        except Exception as e:
            logger.error("An error occurred during logout: %s", e)
            return "An error occurred during logout.", 500
