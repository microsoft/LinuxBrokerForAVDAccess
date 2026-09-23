import logging
import math
import time

import requests
from msal import ConfidentialClientApplication
from flask import request, redirect, url_for, session
from config import CLIENT_ID, TENANT_ID, CLIENT_SECRET, AUTHORITY, AUTHORITY_HOST, API_SCOPE
from function_authentication import PortalAccessError, portal_authority

logger = logging.getLogger(__name__)

def register_route_authentication(app, spa_shell):
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
        except (requests.exceptions.RequestException, ValueError) as e:
            logger.error("Unable to start login (%s).", type(e).__name__)
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
                logger.warning("Microsoft sign-in rejected the authorization code.")

                if result.get("error") == "invalid_grant":
                    return "Invalid authorization code.", 400
                else:
                    return "Sign-in failed. Please try signing in again.", 401

            session.clear()
            session["user"] = result.get("id_token_claims")
            session["access_token"] = result.get("access_token")

            expires_in = result.get("expires_in")
            if (type(expires_in) not in (int, float) or not math.isfinite(expires_in)
                    or expires_in <= 0):
                session.clear()
                raise PortalAccessError(401)
            session["token_expiry"] = time.time() + expires_in

            authority = portal_authority()
            if not authority['capabilities']['manage']:
                logger.info("Portal login denied: administrator access required.")
                return spa_shell(403)
            return redirect(url_for('index', _external=True, _scheme='https')), 302
        except PortalAccessError as error:
            return spa_shell(error.status)
        except (requests.exceptions.RequestException, ValueError, OverflowError) as e:
            logger.error("Unable to complete authorization (%s).", type(e).__name__)
            return "An error occurred during authorization.", 500

    @app.route('/logout')
    def logout():
        session.clear()

        logout_url = (
            f"{AUTHORITY_HOST}/{TENANT_ID}/oauth2/v2.0/logout"
            f"?post_logout_redirect_uri={url_for('index', _external=True)}"
        )
        return redirect(logout_url), 302
