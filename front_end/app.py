import os
import logging

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.frontend')

import requests
from flask import Flask, jsonify, render_template, send_from_directory, session
from flask_session import Session
from flask_wtf.csrf import CSRFProtect, CSRFError

from function_api import NotAuthenticated, api_get, api_post, fetch_vm_summary, summarize_vms
from route_authentication import register_route_authentication
from route_user import register_route_user
from route_vm_management import register_route_vm_management
from route_scaling_management import register_route_scaling_management
from route_host_settings import register_route_host_settings

# ===============================
# Flask App

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('FLASK_KEY') 
app.config['SESSION_TYPE'] = 'filesystem'
app.config['VERSION'] = '0.113'
# Tokens stay valid for the life of the session rather than expiring after an
# hour, so a long-lived management page does not start rejecting submissions.
app.config['WTF_CSRF_TIME_LIMIT'] = None
Session(app)

# Protects the state-changing POST routes (add/delete/release/return VM,
# create/update/delete scaling rule) against cross-site request forgery.
csrf = CSRFProtect(app)

# ===============================
# Logging Configuration

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('linuxbroker.frontend')

# ===============================
# General Routes

@app.route('/')
def index():
    if not session.get('user') or not session.get('access_token'):
        return render_template('index.html', authenticated=False)

    stats = None
    recent_activity = []
    api_error = False

    try:
        stats = fetch_vm_summary()
    except NotAuthenticated:
        return render_template('index.html', authenticated=False)
    except (requests.exceptions.RequestException, ValueError) as e:
        api_error = True
        logger.error("Unable to build dashboard VM summary: %s", e)

    # Secondary panel: never let a scaling-log failure break the dashboard.
    try:
        activity = api_post('/scaling/log', {"limit": 5})
        recent_activity = activity[:5] if isinstance(activity, list) else []
    except (NotAuthenticated, requests.exceptions.RequestException, ValueError) as e:
        logger.warning("Unable to load recent scaling activity for dashboard: %s", e)

    return render_template(
        'index.html',
        authenticated=True,
        stats=stats,
        recent_activity=recent_activity,
        api_error=api_error,
    )

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "version": app.config['VERSION']}), 200

@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.root_path, 'static'), 'favicon.ico', mimetype='image/vnd.microsoft.icon')

# ===============================
# Error Handlers

@app.errorhandler(400)
def handle_bad_request(e):
    return render_template('error.html',
                           code=400,
                           title="Bad request",
                           message="The request could not be understood. Please go back and try again."), 400

@app.errorhandler(403)
def handle_forbidden(e):
    return render_template('error.html',
                           code=403,
                           title="Access denied",
                           message="Your account does not have permission to view this page."), 403

@app.errorhandler(404)
def handle_not_found(e):
    return render_template('error.html',
                           code=404,
                           title="Page not found",
                           message="The page you requested does not exist or may have moved."), 404

@app.errorhandler(CSRFError)
def handle_csrf_error(e):
    logger.warning("CSRF validation failed: %s", getattr(e, 'description', e))
    return render_template('error.html',
                           code=400,
                           title="Session expired",
                           message="Your session expired or the form was no longer valid. "
                                   "Please return to the page and try the action again."), 400

@app.errorhandler(500)
def handle_server_error(e):
    logger.error("Unhandled server error: %s", e)
    return render_template('error.html',
                           code=500,
                           title="Something went wrong",
                           message="An unexpected error occurred. The issue has been logged."), 500

# ===============================
# Authentication

register_route_authentication(app)

# ===============================
# User

register_route_user(app)

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
