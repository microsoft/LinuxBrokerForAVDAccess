"""Scaling rule and scaling history endpoints for the React portal."""

import logging

from flask import jsonify, request

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, BadRequest, broker_endpoint, history_page, json_body, require

logger = logging.getLogger(__name__)

RULE_FIELDS = (
    'minvms',
    'maxvms',
    'scaleupratio',
    'scaleupincrement',
    'scaledownratio',
    'scaledownincrement',
)


def register_route_scaling_management(app):
    @app.route(f'{API_PREFIX}/scaling/rules')
    @login_required
    @broker_endpoint("Unable to retrieve scaling rules. Please try again later.")
    def ui_scaling_rules():
        return jsonify(api_get('/scaling/rules'))

    @app.route(f'{API_PREFIX}/scaling/rules/history')
    @login_required
    @broker_endpoint("Unable to retrieve the scaling rules history. Please try again later.")
    def ui_scaling_rules_history():
        return history_page('/scaling/rules/history')

    @app.route(f'{API_PREFIX}/scaling/rules/<int:ruleid>')
    @login_required
    @broker_endpoint("Unable to retrieve scaling rule details. Please try again later.")
    def ui_scaling_rule_details(ruleid):
        return jsonify(api_get(f'/scaling/rules/{ruleid}'))

    @app.route(f'{API_PREFIX}/scaling/rules', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to create scaling rule. Please try again later.")
    def ui_create_scaling_rule():
        payload = json_body()
        require(payload, *RULE_FIELDS)

        return jsonify(api_post('/scaling/rules/create', _rule_payload(payload))), 201

    @app.route(f'{API_PREFIX}/scaling/rules/<int:ruleid>/update', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to update scaling rule. Please try again later.")
    def ui_update_scaling_rule(ruleid):
        payload = json_body()
        require(payload, *RULE_FIELDS)

        return jsonify(api_post(f'/scaling/rules/{ruleid}/update', _rule_payload(payload)))

    @app.route(f'{API_PREFIX}/scaling/rules/<int:ruleid>/delete', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to delete scaling rule. Please try again later.")
    def ui_delete_scaling_rule(ruleid):
        return jsonify(api_post(f'/scaling/rules/{ruleid}/delete'))

    @app.route(f'{API_PREFIX}/scaling/log')
    @login_required
    @broker_endpoint("Unable to retrieve the scaling activity log. Please try again later.")
    def ui_scaling_activity_log():
        return history_page('/scaling/log')

    # Scaling policy: the time zone, schedule windows and the preview.

    @app.route(f'{API_PREFIX}/scaling/policy')
    @login_required
    @broker_endpoint("Unable to retrieve the scaling policy. Please try again later.")
    def ui_scaling_policy():
        return jsonify(api_get('/scaling/policy'))

    @app.route(f'{API_PREFIX}/scaling/policy', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to update the scaling policy. Please try again later.")
    def ui_update_scaling_policy():
        zone = json_body().get('timezone')
        if not isinstance(zone, str) or not zone.strip():
            raise BadRequest("Choose a time zone.")
        return jsonify(api_post('/scaling/policy/update', {'timezone': zone.strip()[:64]}))

    @app.route(f'{API_PREFIX}/scaling/timezones')
    @login_required
    @broker_endpoint("Unable to list time zones. Please try again later.")
    def ui_time_zones():
        return jsonify(api_get('/scaling/timezones'))

    @app.route(f'{API_PREFIX}/scaling/schedules', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to save the scaling schedule. Please try again later.")
    def ui_create_scaling_schedule():
        return jsonify(api_post('/scaling/schedules/create', _schedule_payload(json_body()))), 201

    @app.route(f'{API_PREFIX}/scaling/schedules/<int:scheduleid>/update', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to save the scaling schedule. Please try again later.")
    def ui_update_scaling_schedule(scheduleid):
        return jsonify(api_post(f'/scaling/schedules/{scheduleid}/update', _schedule_payload(json_body())))

    @app.route(f'{API_PREFIX}/scaling/schedules/<int:scheduleid>/delete', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to delete the scaling schedule. Please try again later.")
    def ui_delete_scaling_schedule(scheduleid):
        return jsonify(api_post(f'/scaling/schedules/{scheduleid}/delete'))

    @app.route(f'{API_PREFIX}/scaling/preview', methods=['GET', 'POST'])
    @login_required
    @broker_endpoint("Unable to preview scaling. Please try again later.")
    def ui_scaling_preview():
        if request.method == 'GET':
            at = (request.args.get('at') or '').strip()[:32]
            return jsonify(api_get('/scaling/preview', params={'at': at} if at else None))

        payload = json_body()
        body = {}
        at = payload.get('at')
        if isinstance(at, str) and at.strip():
            body['at'] = at.strip()[:32]
        rule = payload.get('rule')
        if isinstance(rule, dict):
            body['rule'] = {key: rule[key] for key in (*RULE_FIELDS, 'stopmode', 'name') if key in rule}
        return jsonify(api_post('/scaling/preview', body))


SCHEDULE_FIELDS = ('name', 'days', 'start', 'end', 'enabled', 'stopmode', *RULE_FIELDS)


def _schedule_payload(payload):
    """Forward a schedule window's fields. The broker validates them and names any problem."""
    missing = [field for field in ('name', 'days', 'start', 'end', *RULE_FIELDS)
               if payload.get(field) is None or (isinstance(payload.get(field), str) and not payload[field].strip())]
    if missing:
        raise BadRequest(f"Missing required field(s): {', '.join(missing)}.")
    return {field: payload[field] for field in SCHEDULE_FIELDS if field in payload and payload[field] is not None}


def _rule_payload(payload):
    """Forward rule values, validating the optional stop mode contract."""
    data = {field: payload[field] for field in RULE_FIELDS}
    if 'stopmode' in payload and payload.get('stopmode') not in (None, ''):
        stopmode = str(payload.get('stopmode')).strip()
        if stopmode not in ('PowerOff', 'Deallocate'):
            raise BadRequest("stopmode must be PowerOff or Deallocate.")
        data['stopmode'] = stopmode
    return data
