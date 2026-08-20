import requests
import logging

from flask import request, redirect, url_for, session, render_template, flash
from datetime import datetime
from function_authentication import login_required
from function_api import NotAuthenticated, fetch_history_page
from config import API_URL

logger = logging.getLogger(__name__)

def register_route_vm_management(app):
    @app.route('/vms')
    @login_required
    def view_all_vms():
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.get(f"{API_URL}/vms", headers=headers)
            response.raise_for_status()
            vms = response.json()
            return render_template('vm/view_all_vms.html', vms=vms)
        except requests.exceptions.RequestException as e:
            flash("Unable to retrieve VM data. Please try again later.", "danger")
            logger.error(f"Error retrieving VM data: {e}")
            return redirect(url_for('index'))

    @app.route('/vms/<int:vmid>')
    @login_required
    def view_vm_details(vmid):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.get(f"{API_URL}/vms/{vmid}", headers=headers)
            response.raise_for_status()
            vm = response.json()
            return render_template('vm/view_vm_details.html', vm=vm)
        except requests.exceptions.RequestException as e:
            flash("Unable to retrieve VM details. Please try again later.", "danger")
            logger.error(f"Error retrieving VM details for VMID {vmid}: {e}")
            return redirect(url_for('view_all_vms'))

    @app.route('/vms/add', methods=['GET', 'POST'])
    @login_required
    def add_vm():
        if request.method == 'POST':
            try:
                data = {
                    "hostname": request.form['hostname'],
                    "ipaddress": request.form['ipaddress'],
                    "powerstate": request.form['powerstate'],
                    "networkstatus": request.form['networkstatus'],
                    "vmstatus": request.form['vmstatus'],
                    "username": request.form.get('username', ''),
                    "avdhost": request.form.get('avdhost', ''),
                    "description": request.form.get('description', '')
                }
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.post(f"{API_URL}/vms/add", headers=headers, json=data)
                response.raise_for_status()
                flash("VM added successfully!", "success")
                return redirect(url_for('view_all_vms'))
            except requests.exceptions.RequestException as e:
                flash("Unable to add VM. Please try again later.", "danger")
                logger.error(f"Error adding VM: {e}")
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error(f"Unexpected error in add_vm: {e}")
        return render_template('vm/add_vm.html')

    @app.route('/vms/<int:vmid>/delete', methods=['POST'])
    @login_required
    def delete_vm(vmid):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.post(f"{API_URL}/vms/{vmid}/delete", headers=headers)
            response.raise_for_status()
            flash("VM deleted successfully!", "success")
        except requests.exceptions.RequestException as e:
            flash("Unable to delete VM. Please try again later.", "danger")
            logger.error(f"Error deleting VM with VMID {vmid}: {e}")
        return redirect(url_for('view_all_vms'))

    @app.route('/vms/<int:vmid>/update', methods=['GET', 'POST'])
    @login_required
    def update_vm_attributes(vmid):
        if request.method == 'POST':
            try:
                data = {
                    "powerstate": request.form['powerstate'],
                    "networkstatus": request.form['networkstatus'],
                    "vmstatus": request.form['vmstatus']
                }
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.post(f"{API_URL}/vms/{vmid}/update-attributes", headers=headers, json=data)
                response.raise_for_status()
                flash("VM attributes updated successfully!", "success")
                return redirect(url_for('view_vm_details', vmid=vmid))
            except requests.exceptions.RequestException as e:
                flash("Unable to update VM attributes. Please try again later.", "danger")
                logger.error(f"Error updating VM attributes for VMID {vmid}: {e}")
                return redirect(url_for('view_vm_details', vmid=vmid))
        else:
            try:
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.get(f"{API_URL}/vms/{vmid}", headers=headers)
                response.raise_for_status()
                vm = response.json()
                return render_template('vm/update_vm_attributes.html', vm=vm)
            except requests.exceptions.RequestException as e:
                flash("Unable to retrieve VM details. Please try again later.", "danger")
                logger.error(f"Error retrieving VM details for VMID {vmid}: {e}")
                return redirect(url_for('view_all_vms'))

    @app.route('/vms/checkout', methods=['GET', 'POST'])
    @login_required
    def checkout_vm():
        if request.method == 'POST':
            try:
                data = {
                    "username": request.form['username'],
                    "avdhost": request.form['avdhost']
                }
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.post(f"{API_URL}/vms/checkout", headers=headers, json=data)
                response.raise_for_status()
                vm = response.json()
                flash("Successfully checked out VM!", "success")
                return redirect(url_for('view_vm_details', vmid=vm['VMID']))
            except requests.exceptions.RequestException as e:
                flash("Unable to checkout VM. Please try again later.", "danger")
                logger.error(f"Error checking out VM: {e}")
                return redirect(url_for('view_all_vms'))
        return render_template('vm/checkout_vm.html')

    @app.route('/vms/<hostname>/release', methods=['POST'])
    @login_required
    def release_vm(hostname):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.post(f"{API_URL}/vms/{hostname}/release", headers=headers)
            response.raise_for_status()
            flash(f"VM '{hostname}' released successfully!", "success")
        except requests.exceptions.RequestException as e:
            flash(f"Unable to release VM '{hostname}'. Please try again later.", "danger")
            logger.error(f"Error releasing VM '{hostname}': {e}")
        return redirect(url_for('view_all_vms'))

    @app.route('/vms/<int:vmid>/return', methods=['POST'])
    @login_required
    def return_vm(vmid):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.post(f"{API_URL}/vms/{vmid}/return", headers=headers)
            response.raise_for_status()
            flash(f"VM '{vmid}' returned successfully!", "success")
        except requests.exceptions.RequestException as e:
            flash(f"Unable to return VM '{vmid}'. Please try again later.", "danger")
            logger.error(f"Error returning VM with VMID {vmid}: {e}")
        return redirect(url_for('view_all_vms'))

    @app.route('/vms/history', methods=['GET', 'POST'])
    @login_required
    def vm_history():
        if request.method == 'POST':
            startdate = request.form.get('startdate')
            enddate = request.form.get('enddate')
            limit = request.form.get('limit', '')

            ignore_dates = request.form.get('ignore_dates')
            ignore_limit = request.form.get('ignore_limit')

            # Validate before storing so a bad date is reported against the form the
            # operator is looking at, rather than surfacing later as a query failure.
            if not ignore_dates:
                for label, value in (("start", startdate), ("end", enddate)):
                    if not value:
                        continue
                    try:
                        datetime.strptime(value, '%Y-%m-%d')
                    except ValueError:
                        flash(f"Invalid {label} date format. Please use 'YYYY-MM-DD'.", "danger")
                        return redirect(url_for('vm_history'))

            # Only the criteria are stored. Results are fetched a page at a time on the
            # GET, so the session no longer holds an unbounded result set and two
            # browser tabs cannot clobber each other's results.
            session['vm_history_filters'] = {
                "startdate": startdate or "",
                "enddate": enddate or "",
                "limit": limit if limit and limit != "null" else "",
                "ignore_dates": bool(ignore_dates),
                "ignore_limit": bool(ignore_limit),
            }
            session.pop('vm_history', None)
            session.pop('vm_history_data', None)

            return redirect(url_for('vm_history'))

        filters = session.get('vm_history_filters') or {
            "startdate": "",
            "enddate": "",
            "limit": "",
            "ignore_dates": False,
            "ignore_limit": False,
        }

        try:
            page = max(1, int(request.args.get('page', 1)))
        except (TypeError, ValueError):
            page = 1
        try:
            per_page = min(200, max(1, int(request.args.get('per_page', 10))))
        except (TypeError, ValueError):
            per_page = 10

        try:
            rows, total_items, total_pages = fetch_history_page(
                '/vms/history', filters, page, per_page
            )
        except NotAuthenticated:
            return redirect(url_for('login'))
        except (requests.exceptions.RequestException, ValueError) as e:
            flash("Unable to retrieve VM history. Please try again later.", "danger")
            logger.error("Error retrieving VM history: %s", e)
            return redirect(url_for('view_all_vms'))

        return render_template('vm/vm_history.html',
                               vm_history=rows,
                               page=page,
                               total_pages=total_pages,
                               per_page=per_page,
                               total_items=total_items,
                               filters=filters)
