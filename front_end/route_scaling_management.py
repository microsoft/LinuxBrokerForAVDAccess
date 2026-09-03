"""Scaling rule and scaling history endpoints for the React portal."""

import logging

from flask import jsonify

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, broker_endpoint, history_page, json_body, require

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


def _rule_payload(payload):
    """The broker validates and coerces these, so they are forwarded as sent."""
    return {field: payload[field] for field in RULE_FIELDS}
