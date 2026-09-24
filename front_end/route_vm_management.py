"""VM management endpoints for the React portal.

These return JSON rather than rendering templates. Everything reaches the broker
through `function_api`, so the bearer token, request timeout and JSON decoding are
handled in one place instead of being rebuilt in every view.
"""

import logging

from flask import jsonify

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, BadRequest, broker_endpoint, history_page, json_body, require

logger = logging.getLogger(__name__)


def register_route_vm_management(app):
    @app.route(f'{API_PREFIX}/vms')
    @login_required
    @broker_endpoint("Unable to retrieve VM data. Please try again later.")
    def ui_vms():
        return jsonify(api_get('/vms'))

    # Registered before the /vms/<int:vmid> rule for readability; Werkzeug matches
    # the static path first regardless.
    @app.route(f'{API_PREFIX}/vms/history')
    @login_required
    @broker_endpoint("Unable to retrieve VM history. Please try again later.")
    def ui_vm_history():
        return history_page('/vms/history')

    @app.route(f'{API_PREFIX}/vms/<int:vmid>')
    @login_required
    @broker_endpoint("Unable to retrieve VM details. Please try again later.")
    def ui_vm_details(vmid):
        return jsonify(api_get(f'/vms/{vmid}'))

    @app.route(f'{API_PREFIX}/vms', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to add VM. Please try again later.")
    def ui_add_vm():
        payload = json_body()
        require(payload, 'hostname', 'ipaddress', 'powerstate', 'networkstatus', 'vmstatus')

        return jsonify(api_post('/vms/add', {
            "hostname": payload['hostname'],
            "ipaddress": payload['ipaddress'],
            "powerstate": payload['powerstate'],
            "networkstatus": payload['networkstatus'],
            "vmstatus": payload['vmstatus'],
            # Blank optional fields are sent as null; an empty username would make the
            # broker treat the new host as assigned.
            "username": (payload.get('username') or '').strip() or None,
            "avdhost": (payload.get('avdhost') or '').strip() or None,
            "description": (payload.get('description') or '').strip() or None,
        })), 201

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/update-attributes', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to update VM attributes. Please try again later.")
    def ui_update_vm_attributes(vmid):
        payload = json_body()
        powerstate, networkstatus, vmstatus = require(
            payload, 'powerstate', 'networkstatus', 'vmstatus'
        )

        return jsonify(api_post(f'/vms/{vmid}/update-attributes', {
            "powerstate": powerstate,
            "networkstatus": networkstatus,
            "vmstatus": vmstatus,
        }))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/delete', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to delete VM. Please try again later.")
    def ui_delete_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/delete'))

    @app.route(f'{API_PREFIX}/vms/<hostname>/release', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to release the VM. Please try again later.")
    def ui_release_vm(hostname):
        return jsonify(api_post(f'/vms/{hostname}/release'))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/return', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to return the VM. Please try again later.")
    def ui_return_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/return'))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/cleanup', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to retry VM cleanup. Please try again later.")
    def ui_cleanup_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/cleanup'))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/maintenance', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to update VM maintenance. Please try again later.")
    def ui_maintenance_vm(vmid):
        payload = json_body()
        if 'enabled' not in payload or not isinstance(payload.get('enabled'), bool):
            raise BadRequest("enabled must be a boolean.")
        return jsonify(api_post(f'/vms/{vmid}/maintenance', {"enabled": payload['enabled']}))

    @app.route(f'{API_PREFIX}/vms/checkout', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to check out a VM. Please try again later.")
    def ui_checkout_vm():
        payload = json_body()
        username, avdhost = require(payload, 'username', 'avdhost')

        result = api_post('/vms/checkout', {"username": username, "avdhost": avdhost})
        if isinstance(result, dict):
            result.pop("password", None)
            result.pop("LeaseId", None)
        return jsonify(result)
