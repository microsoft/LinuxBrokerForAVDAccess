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

STOP_MODES = ('PowerOff', 'Deallocate')
SYNC_TIMEOUT_SECONDS = 60


def _confirmation(payload):
    """The hostname the operator typed to confirm acting on a host that is in use."""
    confirm = payload.get('confirm')
    if isinstance(confirm, str) and confirm.strip():
        return {'confirm': confirm.strip()[:255]}
    return {}


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

    # Real power actions. A host with a user assigned is only stopped or restarted when the
    # request names it in `confirm`; the broker enforces that, and the Admin role, itself.
    @app.route(f'{API_PREFIX}/vms/<int:vmid>/start', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to start the VM. Please try again later.")
    def ui_start_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/start'))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/stop', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to stop the VM. Please try again later.")
    def ui_stop_vm(vmid):
        payload = json_body()
        body = _confirmation(payload)
        mode = payload.get('mode')
        if mode not in (None, ''):
            if mode not in STOP_MODES:
                raise BadRequest("mode must be PowerOff or Deallocate.")
            body['mode'] = mode
        return jsonify(api_post(f'/vms/{vmid}/stop', body))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/restart', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to restart the VM. Please try again later.")
    def ui_restart_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/restart', _confirmation(json_body())))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/drain', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to drain the VM. Please try again later.")
    def ui_drain_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/drain'))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/undrain', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to return the VM to service. Please try again later.")
    def ui_undrain_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/undrain'))

    @app.route(f'{API_PREFIX}/vms/sync', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to sync power states from Azure. Please try again later.")
    def ui_sync_power_states():
        # The broker reads every host's power state from Azure, in parallel, within 30 seconds.
        return jsonify(api_post('/vms/sync', timeout=SYNC_TIMEOUT_SECONDS))

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
