import os
import logging

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.frontend')

import requests
from flask import Flask, jsonify, request, send_from_directory, session
from flask_session import Session
from flask_wtf.csrf import CSRFProtect, CSRFError, generate_csrf

from function_api import NotAuthenticated, api_post, fetch_vm_summary
from function_authentication import login_required
from function_bff import API_PREFIX, json_error
from route_authentication import register_route_authentication
from route_vm_management import register_route_vm_management
from route_scaling_management import register_route_scaling_management
from route_host_settings import register_route_host_settings

# ===============================
# Flask App

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('FLASK_KEY')
app.config['SESSION_TYPE'] = 'filesystem'
app.config['VERSION'] = '0.114'
# Tokens stay valid for the life of the session rather than expiring after an
# hour, so a long-lived management page does not start rejecting submissions.
app.config['WTF_CSRF_TIME_LIMIT'] = None
Session(app)

# Protects the state-changing endpoints. The React client reads the token from
# /api/ui/session and sends it back as the X-CSRFToken header, which CSRFProtect
# already accepts alongside the old form field.
csrf = CSRFProtect(app)

# Vite writes the built single-page app here. The folder is generated during the
# image build and is not committed.
SPA_DIST = os.path.join(app.root_path, 'static', 'dist')
SPA_ENTRY = 'index.html'

# ===============================
# Logging Configuration

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('linuxbroker.frontend')

# ===============================
# Single-page app shell


def spa_shell(status=200):
    """Serve the built React app.

    Every non-API path returns this, so a hard refresh or a bookmarked deep link
    still resolves and React Router renders the matching page.
    """
    if not os.path.exists(os.path.join(SPA_DIST, SPA_ENTRY)):
        logger.error("The portal bundle is missing from %s.", SPA_DIST)
        return (
            "The portal front end has not been built. Run `npm ci && npm run build` in "
            "front_end/web, or build the container image, which does it for you.\n",
            500,
            {"Content-Type": "text/plain; charset=utf-8"},
        )

    response = send_from_directory(SPA_DIST, SPA_ENTRY)
    # The shell names hashed asset files, so it must not be cached itself; otherwise
    # a deploy leaves browsers asking for assets that no longer exist.
    response.headers['Cache-Control'] = 'no-store'
    return response, status


@app.route('/')
def index():
    return spa_shell()


@app.route('/<path:requested_path>')
def spa_catch_all(requested_path):
    """Client-side routes.

    An unknown page path still returns the shell and React renders the not-found
    state, which keeps a single error experience. An unknown API path must not,
    because the client is expecting JSON there.
    """
    if request.path.startswith(API_PREFIX):
        return json_error("That endpoint does not exist.", 404)
    return spa_shell()


@app.route('/health')
def health():
    return jsonify({"status": "healthy", "version": app.config['VERSION']}), 200


@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.root_path, 'static'), 'favicon.ico',
                               mimetype='image/vnd.microsoft.icon')

# ===============================
# Session and dashboard


@app.route(f'{API_PREFIX}/session')
def ui_session():
    """Bootstrap payload for the SPA.

    Deliberately not behind @login_required: the signed-out landing page needs a
    successful response that simply reports `authenticated: false`.
    """
    user = session.get('user')
    # A malformed session must not produce a half-authenticated state: without
    # usable claims there is no user to report, so treat it as signed out and let
    # the client send the operator back through sign-in.
    claims = user if isinstance(user, dict) else {}
    authenticated = bool(claims) and bool(session.get('access_token'))

    return jsonify({
        "authenticated": authenticated,
        "version": app.config['VERSION'],
        # Tied to the session and required on every state-changing request.
        "csrfToken": generate_csrf(),
        "user": {
            "name": claims.get('name'),
            "username": claims.get('preferred_username'),
            "objectId": claims.get('oid'),
            "tenantId": claims.get('tid'),
        } if authenticated else None,
    })


@app.route(f'{API_PREFIX}/dashboard')
@login_required
def ui_dashboard():
    """Aggregate pool counters plus the most recent scaling activity.

    Registered here rather than in a route module because it spans both VM and
    scaling data.
    """
    stats = None
    recent_activity = []
    api_error = False

    try:
        stats = fetch_vm_summary()
    except NotAuthenticated:
        return json_error("Your session has expired. Please sign in again.", 401)
    except (requests.exceptions.RequestException, ValueError) as e:
        api_error = True
        logger.error("Unable to build dashboard VM summary: %s", e)

    # Secondary panel: never let a scaling-log failure break the dashboard.
    try:
        activity = api_post('/scaling/log', {"limit": 5})
        recent_activity = activity[:5] if isinstance(activity, list) else []
    except (NotAuthenticated, requests.exceptions.RequestException, ValueError) as e:
        logger.warning("Unable to load recent scaling activity for dashboard: %s", e)

    return jsonify({
        "stats": stats,
        "recentActivity": recent_activity,
        "apiError": api_error,
    })

# ===============================
# Error Handlers


def _wants_json():
    return request.path.startswith(API_PREFIX)


@app.errorhandler(400)
def handle_bad_request(e):
    if _wants_json():
        return json_error(getattr(e, 'description', None) or "The request could not be understood.", 400)
    return spa_shell(400)


@app.errorhandler(403)
def handle_forbidden(e):
    if _wants_json():
        return json_error("Your account does not have permission to perform this action.", 403)
    return spa_shell(403)


@app.errorhandler(404)
def handle_not_found(e):
    if _wants_json():
        return json_error("That endpoint does not exist.", 404)
    return spa_shell(404)


@app.errorhandler(405)
def handle_method_not_allowed(e):
    if _wants_json():
        return json_error("That method is not allowed on this endpoint.", 405)
    return spa_shell(405)


@app.errorhandler(CSRFError)
def handle_csrf_error(e):
    logger.warning("CSRF validation failed: %s", getattr(e, 'description', e))
    message = ("Your session expired or the request was no longer valid. "
               "Please reload the page and try the action again.")
    if _wants_json():
        return json_error(message, 400)
    return spa_shell(400)


@app.errorhandler(500)
def handle_server_error(e):
    logger.error("Unhandled server error: %s", e)
    if _wants_json():
        return json_error("An unexpected error occurred. The issue has been logged.", 500)
    return spa_shell(500)

# ===============================
# Authentication

register_route_authentication(app)

# ===============================
# VM Management

register_route_vm_management(app)

# ===============================
# Scaling and Scaling Rules

register_route_scaling_management(app)

# ===============================
# Linux Host Settings

register_route_host_settings(app)

# ===============================
# Main

if __name__ == '__main__':
    app.run(debug=True)
