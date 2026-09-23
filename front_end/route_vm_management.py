"""VM management endpoints for the React portal.

These return JSON rather than rendering templates. Everything reaches the broker
through `function_api`, so the bearer token, request timeout and JSON decoding are
handled in one place instead of being rebuilt in every view.
"""

import logging
from uuid import UUID

from flask import abort, jsonify

from function_authentication import login_required
from function_api import api_get, api_post
from function_bff import API_PREFIX, BadRequest, broker_endpoint, history_page, json_body, require

logger = logging.getLogger(__name__)

# The JSON wire must remain exact in JavaScript and older jq, even with BIGINT storage.
MAX_LEASE_GENERATION = 9_007_199_254_740_991

LEASE_CONFLICT = (
    "The VM lease changed. Refresh the VM and review its current assignment before trying again."
)


def _lease_guard():
    payload = json_body()
    lease_id, generation = require(payload, 'leaseId', 'leaseGeneration')
    if payload.keys() - {'leaseId', 'leaseGeneration'}:
        raise BadRequest("Lease mutations accept only leaseId and leaseGeneration.")
    try:
        if not isinstance(lease_id, str):
            raise ValueError
        UUID(lease_id)
    except ValueError:
        raise BadRequest("leaseId must be the current VM lease ID.") from None
    if type(generation) is not int or not 1 <= generation <= MAX_LEASE_GENERATION:
        raise BadRequest(
            f"leaseGeneration must be the current positive integer generation, at most {MAX_LEASE_GENERATION}."
        )
    return {"leaseId": lease_id, "leaseGeneration": generation}


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
        allowed = {'hostname', 'ipaddress', 'powerstate', 'networkstatus', 'vmstatus', 'description'}
        if payload.keys() - allowed:
            raise BadRequest("VM creation accepts host attributes only, not assignment or lease fields.")
        if payload['vmstatus'] not in ('Available', 'Maintenance'):
            raise BadRequest("A new VM must be Available or Maintenance, without an assigned lease.")

        return jsonify(api_post('/vms/add', {
            "hostname": payload['hostname'],
            "ipaddress": payload['ipaddress'],
            "powerstate": payload['powerstate'],
            "networkstatus": payload['networkstatus'],
            "vmstatus": payload['vmstatus'],
            "description": payload.get('description') or '',
        })), 201

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/update-attributes', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to update VM attributes. Please try again later.")
    def ui_update_vm_attributes(vmid):
        payload = json_body()
        powerstate, networkstatus, vmstatus = require(
            payload, 'powerstate', 'networkstatus', 'vmstatus'
        )
        if payload.keys() - {'powerstate', 'networkstatus', 'vmstatus'}:
            raise BadRequest("VM updates accept powerstate, networkstatus, and vmstatus only.")
        if vmstatus not in ('Available', 'Maintenance'):
            raise BadRequest("Manual VM status must be Available or Maintenance, without an assigned lease.")

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
    @broker_endpoint("Unable to release the VM. Please try again later.", LEASE_CONFLICT)
    def ui_release_vm(hostname):
        if hostname.casefold() == 'checkout':
            abort(404)
        return jsonify(api_post(f'/vms/{hostname}/release', _lease_guard()))

    @app.route(f'{API_PREFIX}/vms/<int:vmid>/return', methods=['POST'])
    @login_required
    @broker_endpoint("Unable to return the VM. Please try again later.", LEASE_CONFLICT)
    def ui_return_vm(vmid):
        return jsonify(api_post(f'/vms/{vmid}/return', _lease_guard()))
