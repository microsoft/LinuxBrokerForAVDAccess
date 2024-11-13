import requests
import logging

from flask import request, redirect, url_for, session, render_template, flash
from datetime import datetime
from function_authentication import login_required
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
            try:
                startdate = request.form.get('startdate')
                enddate = request.form.get('enddate')
                limit = request.form.get('limit', 'null')

                ignore_dates = request.form.get('ignore_dates')
                ignore_limit = request.form.get('ignore_limit')

                if ignore_limit:
                    limit = "null"

                if ignore_dates:
                    startdate = "null"
                    enddate = "null"
                else:
                    if startdate:
                        try:
                            startdate = datetime.strptime(startdate, '%Y-%m-%d').strftime('%m/%d/%Y')
                        except ValueError:
                            flash("Invalid start date format. Please use 'YYYY-MM-DD'.", "danger")
                            return redirect(url_for('vm_history'))
                    else:
                        startdate = "null"

                    if enddate:
                        try:
                            enddate = datetime.strptime(enddate, '%Y-%m-%d').strftime('%m/%d/%Y')
                        except ValueError:
                            flash("Invalid end date format. Please use 'YYYY-MM-DD'.", "danger")
                            return redirect(url_for('vm_history'))
                    else:
                        enddate = "null"

                data = {
                    "startdate": startdate,
                    "enddate": enddate,
                    "limit": limit if limit else "null"
                }

                session['vm_history_data'] = data

                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}

                response = requests.post(f"{API_URL}/vms/history", headers=headers, json=data)
                response.raise_for_status()

                vm_history = response.json()

                if not vm_history:
                    flash("No VM history records found for the specified criteria.", "info")
                else:
                    flash("VM history retrieved successfully!", "success")

                session['vm_history'] = vm_history

                return redirect(url_for('vm_history'))
            except requests.exceptions.RequestException as e:
                flash("Unable to retrieve VM history. Please try again later.", "danger")
                logger.error(f"Error retrieving VM history: {e}")
                return redirect(url_for('view_all_vms'))
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error(f"Unexpected error in vm_history POST: {e}")
                return redirect(url_for('view_all_vms'))
        else:
            try:
                vm_history = session.get('vm_history', [])
                page = max(1, int(request.args.get('page', 1)))
                per_page = max(1, int(request.args.get('per_page', 10)))

                total_items = len(vm_history)
                total_pages = (total_items + per_page - 1) // per_page

                start = (page - 1) * per_page
                end = start + per_page
                vm_history_paginated = vm_history[start:end]

                logger.debug(f"Displaying VM history page {page} of {total_pages}, items {start} to {end}")

                return render_template('vm/vm_history.html', 
                                       vm_history=vm_history_paginated, 
                                       page=page, 
                                       total_pages=total_pages,
                                       per_page=per_page)
            except Exception as e:
                flash("An unexpected error occurred while displaying VM history.", "danger")
                logger.error(f"Unexpected error in vm_history GET: {e}")
                return redirect(url_for('view_all_vms'))
