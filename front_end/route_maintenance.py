"""Rolling maintenance endpoints for the React portal."""

import logging
import re

import requests
from flask import jsonify, request

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, BadRequest, broker_endpoint, json_body

logger = logging.getLogger(__name__)

HOSTNAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
MAX_HOSTNAMES = 500
PATCH_MODES = ('Security', 'All', 'RebootOnly')
# The settings a new run may carry, forwarded as sent; the broker validates their values.
RUN_FIELDS = (
    'name', 'patchMode', 'batchSize', 'minReady', 'signOutDeadlineMinutes', 'warningMinutes', 'warningMessage',
    'includePoweredOff', 'maxFailures', 'canaryCount',
)
RUN_ACTIONS = ('pause', 'resume', 'cancel')
REASON_MAX = 400


def _run_body(payload):
    hostnames = payload.get('hostnames')
    if (not isinstance(hostnames, list) or not hostnames or len(hostnames) > MAX_HOSTNAMES
            or not all(isinstance(name, str) and HOSTNAME_RE.match(name) for name in hostnames)):
        raise BadRequest(f"Choose between 1 and {MAX_HOSTNAMES} hosts.")
    if payload.get('patchMode') not in PATCH_MODES:
        raise BadRequest("patchMode must be Security, All or RebootOnly.")
    body = {field: payload[field] for field in RUN_FIELDS if field in payload}
    body['hostnames'] = hostnames
    return body


def register_route_maintenance(app):
    @app.route(f'{API_PREFIX}/maintenance/runs')
    @login_required
    @broker_endpoint("Unable to retrieve maintenance runs. Please try again later.")
    def ui_maintenance_runs():
        try:
            body = api_get('/maintenance/runs')
        except requests.exceptions.HTTPError as e:
            if getattr(getattr(e, 'response', None), 'status_code', None) != 404:
                raise
            logger.info("The broker has no rolling maintenance yet.")
            return jsonify({'Available': False, 'Runs': [], 'Active': None})
        return jsonify(dict(body if isinstance(body, dict) else {}, Available=True))

    @app.route(f'{API_PREFIX}/maintenance/runs/<int:run_id>')
    @login_required
    @broker_endpoint("Unable to retrieve the maintenance run. Please try again later.")
    def ui_maintenance_run(run_id):
        return jsonify(api_get(f'/maintenance/runs/{run_id}'))

    @app.route(f'{API_PREFIX}/maintenance/runs', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to start the maintenance run. Please try again later.")
    def ui_create_maintenance_run():
        return jsonify(api_post('/maintenance/runs/create', _run_body(json_body()))), 201

    @app.route(f'{API_PREFIX}/maintenance/runs/<int:run_id>/<action>', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to change the maintenance run. Please try again later.")
    def ui_change_maintenance_run(run_id, action):
        if action not in RUN_ACTIONS:
            raise BadRequest("The action must be pause, resume or cancel.")
        reason = json_body().get('reason')
        body = {'reason': reason.strip()[:REASON_MAX]} if isinstance(reason, str) and reason.strip() else {}
        return jsonify(api_post(f'/maintenance/runs/{run_id}/{action}', body))
