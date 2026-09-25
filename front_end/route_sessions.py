"""Sessions and users endpoints for the React portal."""

import logging
import re

from flask import jsonify, request

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, BadRequest, broker_endpoint, json_body

logger = logging.getLogger(__name__)

# The forms the broker accepts, checked here too so a hand-edited URL never reaches it.
HOSTNAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
USERNAME_RE = re.compile(r'^[A-Za-z0-9_]{1,64}$')
SESSION_STATES = (
    'active', 'disconnected', 'released', 'connecting', 'not-connected',
    'cleanup-pending', 'unmanaged', 'unknown',
)
MESSAGE_MAX_CHARS = 500

# Signing out and returning runs the sign-out, the release, the return and the host cleanup,
# each bounded by the broker; a message is one SSH call. A broadcast is bounded by the
# broker's own deadline, which stays under this.
SIGNOUT_TIMEOUT_SECONDS = 120
MESSAGE_TIMEOUT_SECONDS = 45
BROADCAST_TIMEOUT_SECONDS = 110
BROADCAST_MAX_HOSTNAMES = 500


def _hostname(value):
    if not HOSTNAME_RE.match(value or ''):
        raise BadRequest("The hostname is not valid.")
    return value


def _username(value):
    if not USERNAME_RE.match(value or ''):
        raise BadRequest("The username is not valid.")
    return value


def _message(payload):
    message = payload.get('message')
    if not isinstance(message, str) or not message.strip():
        raise BadRequest("Provide the message to send.")
    if len(message.strip()) > MESSAGE_MAX_CHARS:
        raise BadRequest(f"The message must be at most {MESSAGE_MAX_CHARS} characters.")
    return message.strip()


def register_route_sessions(app):
    @app.route(f'{API_PREFIX}/sessions')
    @login_required
    @broker_endpoint("Unable to retrieve sessions. Please try again later.")
    def ui_sessions():
        params = {}
        query = (request.args.get('q') or '').strip()[:128]
        if query:
            params['q'] = query
        state = (request.args.get('state') or '').strip().lower()
        if state:
            if state not in SESSION_STATES:
                raise BadRequest(f"state must be one of: {', '.join(SESSION_STATES)}.")
            params['state'] = state
        return jsonify(api_get('/sessions', params=params or None))

    @app.route(f'{API_PREFIX}/users')
    @login_required
    @broker_endpoint("Unable to search users. Please try again later.")
    def ui_search_users():
        params = {}
        query = (request.args.get('q') or '').strip()[:64]
        if query:
            params['q'] = query
        limit = (request.args.get('limit') or '').strip()
        if limit.isdigit():
            params['limit'] = limit
        return jsonify(api_get('/users', params=params or None))

    @app.route(f'{API_PREFIX}/users/<username>')
    @login_required
    @broker_endpoint("Unable to retrieve the user. Please try again later.")
    def ui_user_details(username):
        return jsonify(api_get(f'/users/{_username(username)}'))

    @app.route(f'{API_PREFIX}/sessions/<hostname>/<username>/signout', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to sign the user out. Please try again later.")
    def ui_sign_out_session(hostname, username):
        body = {'returnHost': True} if json_body().get('returnHost') is True else {}
        return jsonify(api_post(
            f'/sessions/{_hostname(hostname)}/{_username(username)}/signout', body,
            timeout=SIGNOUT_TIMEOUT_SECONDS,
        ))

    @app.route(f'{API_PREFIX}/sessions/<hostname>/<username>/message', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to send the message. Please try again later.")
    def ui_message_session(hostname, username):
        message = _message(json_body())
        return jsonify(api_post(
            f'/sessions/{_hostname(hostname)}/{_username(username)}/message', {'message': message},
            timeout=MESSAGE_TIMEOUT_SECONDS,
        ))

    @app.route(f'{API_PREFIX}/sessions/broadcast', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to send the message. Please try again later.")
    def ui_broadcast():
        payload = json_body()
        body = {'message': _message(payload)}
        hostnames = payload.get('hostnames')
        if hostnames is not None:
            if (not isinstance(hostnames, list) or not hostnames or len(hostnames) > BROADCAST_MAX_HOSTNAMES
                    or not all(isinstance(name, str) and HOSTNAME_RE.match(name) for name in hostnames)):
                raise BadRequest(f"hostnames must be a list of 1 to {BROADCAST_MAX_HOSTNAMES} hostnames.")
            body['hostnames'] = hostnames
        return jsonify(api_post('/sessions/broadcast', body, timeout=BROADCAST_TIMEOUT_SECONDS))

    @app.route(f'{API_PREFIX}/users/<username>/reset-profile', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to request the profile reset. Please try again later.")
    def ui_request_profile_reset(username):
        confirm = json_body().get('confirm')
        body = {'confirm': confirm.strip()[:64]} if isinstance(confirm, str) and confirm.strip() else {}
        return jsonify(api_post(f'/users/{_username(username)}/reset-profile', body))

    @app.route(f'{API_PREFIX}/users/<username>/reset-profile/cancel', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to cancel the profile reset. Please try again later.")
    def ui_cancel_profile_reset(username):
        return jsonify(api_post(f'/users/{_username(username)}/reset-profile/cancel'))
