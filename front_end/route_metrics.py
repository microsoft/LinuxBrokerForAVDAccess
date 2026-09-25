"""Dashboard metrics for the React portal: capacity over time and the Attention panel.

Both are optional on the dashboard. An API or database that predates them answers 404, which
becomes Available: false so the portal hides the panel instead of reporting an error.
"""

import logging

import requests
from flask import jsonify, request

from function_authentication import login_required
from function_api import api_get
from function_bff import API_PREFIX, BadRequest, broker_endpoint

logger = logging.getLogger(__name__)

UTILIZATION_HOURS = ('24', '168')


def _not_found(error):
    return getattr(getattr(error, 'response', None), 'status_code', None) == 404


def register_route_metrics(app):
    @app.route(f'{API_PREFIX}/metrics/utilization')
    @login_required
    @broker_endpoint("Unable to retrieve capacity trends. Please try again later.")
    def ui_utilization_metrics():
        hours = (request.args.get('hours') or '24').strip()
        if hours not in UTILIZATION_HOURS:
            raise BadRequest("hours must be 24 or 168.")
        try:
            body = api_get('/metrics/utilization', params={'hours': hours})
        except requests.exceptions.HTTPError as e:
            if not _not_found(e):
                raise
            logger.info("The broker has no capacity trends yet; hiding the chart.")
            return jsonify({'Available': False, 'Hours': int(hours)})
        return jsonify(dict(body if isinstance(body, dict) else {}, Available=True))

    @app.route(f'{API_PREFIX}/metrics/attention')
    @login_required
    @broker_endpoint("Unable to retrieve what needs attention. Please try again later.")
    def ui_attention_items():
        try:
            body = api_get('/metrics/attention')
        except requests.exceptions.HTTPError as e:
            if not _not_found(e):
                raise
            logger.info("The broker has no attention items yet; hiding the panel.")
            return jsonify({'Available': False, 'Items': [], 'Summary': {'Total': 0}, 'Incomplete': True})
        return jsonify(dict(body if isinstance(body, dict) else {}, Available=True))
