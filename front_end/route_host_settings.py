"""Linux host settings endpoints for the React portal."""

import logging

import requests
from flask import jsonify, session

from function_api import NotAuthenticated, api_get, api_post
from function_authentication import login_required
from function_bff import API_PREFIX, BadRequest, broker_endpoint, json_body

logger = logging.getLogger(__name__)

# Client field name -> API payload field. Keeping this in one place means the form,
# the submit handler and the API request stay in step.
INTEGER_FIELDS = {
    'graceperiodseconds': 'GracePeriodSeconds',
    'reconcileintervalseconds': 'ReconcileIntervalSeconds',
    'watcherdebounceseconds': 'WatcherDebounceSeconds',
    'watchersettleseconds': 'WatcherSettleSeconds',
    'idletimeoutseconds': 'IdleTimeoutSeconds',
    'idlewarningseconds': 'IdleWarningSeconds',
    'screenidledelayseconds': 'ScreenIdleDelaySeconds',
    'screenlockdelayseconds': 'ScreenLockDelaySeconds',
}

BOOLEAN_FIELDS = {
    'screenlockenabled': 'ScreenLockEnabled',
    'disablelockscreen': 'DisableLockScreen',
    'screenlocksettingslocked': 'ScreenLockSettingsLocked',
}


def register_route_host_settings(app):
    @app.route(f'{API_PREFIX}/hosts/settings')
    @login_required
    @broker_endpoint("Unable to retrieve host settings. Please try again later.")
    def ui_host_settings():
        settings = api_get('/hosts/settings')

        # A failure here must not hide the settings form, so the drift table degrades
        # to empty rather than taking the whole page down.
        try:
            hosts = api_get('/vms')
        except (NotAuthenticated, requests.exceptions.RequestException, ValueError) as e:
            hosts = []
            logger.warning("Unable to load hosts for the settings drift table: %s", e)

        return jsonify({"settings": settings, "hosts": hosts})

    @app.route(f'{API_PREFIX}/hosts/settings', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to save host settings. Please try again later.")
    def ui_update_host_settings():
        payload = json_body()
        data = {}

        for field, api_field in INTEGER_FIELDS.items():
            raw = payload.get(field)
            if raw is None or str(raw).strip() == '':
                continue
            try:
                data[api_field] = int(str(raw).strip())
            except ValueError:
                raise BadRequest(f"{api_field} must be a whole number of seconds.")

        # An omitted boolean must be sent explicitly as false rather than left out,
        # which the API would read as "leave unchanged".
        for field, api_field in BOOLEAN_FIELDS.items():
            data[api_field] = bool(payload.get(field))

        user = session.get('user') or {}
        if isinstance(user, dict):
            data['updatedBy'] = user.get('preferred_username') or user.get('name')

        settings = api_post('/hosts/settings/update', data)

        return jsonify({
            "settings": settings,
            "message": ("Host settings saved. Linux hosts pick these up on their next reconcile "
                        "run, or use Apply Now to push immediately."),
            "tone": "success",
        })

    @app.route(f'{API_PREFIX}/hosts/settings/apply', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to push host settings. Please try again later.")
    def ui_apply_host_settings():
        hostname = (json_body().get('hostname') or '').strip()
        result = api_post('/hosts/settings/apply', {'hostnames': [hostname]} if hostname else {})

        return jsonify(_apply_summary(result))


def _apply_summary(result):
    """Describe an Apply Now push.

    The wording lives here rather than in the client so the "converges on its own"
    reassurance stays attached to the semantics it describes.
    """
    result = result if isinstance(result, dict) else {}
    target_count = result.get('TargetCount') or 0
    succeeded = result.get('SucceededCount') or 0
    unreachable = [entry.get('Hostname') for entry in (result.get('Results') or [])
                   if not entry.get('Applied')]
    unreachable = [name for name in unreachable if name]

    if target_count == 0:
        message = ("No reachable Linux hosts were found to push to. Hosts still converge on "
                   "their own at their next reconcile run.")
        tone = "info"
    elif succeeded == target_count:
        message = f"Applied settings to {succeeded} of {target_count} host(s)."
        tone = "success"
    else:
        message = (f"Applied settings to {succeeded} of {target_count} host(s). "
                   f"Unreachable: {', '.join(unreachable)}. "
                   "These converge on their next reconcile run.")
        tone = "warning"

    return {
        "settingsVersion": result.get('SettingsVersion'),
        "targetCount": target_count,
        "succeededCount": succeeded,
        "unreachable": unreachable,
        "message": message,
        "tone": tone,
    }
