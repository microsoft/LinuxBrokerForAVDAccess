import requests
import logging

from flask import request, redirect, url_for, session, render_template, flash
from function_authentication import login_required
from config import API_URL

logger = logging.getLogger(__name__)

# Field name in the form -> field name in the API payload. Keeping this in one place means
# the form, the submit handler, and the template stay in step.
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
    'screenlocksettingslocked': 'ScreenLockSettingsLocked',
}


def register_route_host_settings(app):
    def _headers():
        access_token = session.get("access_token")
        if not access_token:
            return None
        return {'Authorization': f'Bearer {access_token}'}

    def _load_settings(headers):
        response = requests.get(f"{API_URL}/hosts/settings", headers=headers)
        response.raise_for_status()
        return response.json()

    def _load_hosts(headers):
        """VM list, used to show which hosts have actually applied the current version."""
        try:
            response = requests.get(f"{API_URL}/vms", headers=headers)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Error retrieving hosts for settings drift view: {e}")
            return []

    @app.route('/settings/hosts', methods=['GET', 'POST'])
    @login_required
    def host_settings():
        headers = _headers()
        if not headers:
            return redirect(url_for('login'))

        if request.method == 'POST':
            data = {}

            for form_field, api_field in INTEGER_FIELDS.items():
                raw = request.form.get(form_field, '').strip()
                if raw == '':
                    continue
                try:
                    data[api_field] = int(raw)
                except ValueError:
                    flash(f"{api_field} must be a whole number of seconds.", "danger")
                    return redirect(url_for('host_settings'))

            # Unchecked checkboxes are absent from the form, so they must be sent explicitly
            # as false rather than omitted, which the API would read as "leave unchanged".
            for form_field, api_field in BOOLEAN_FIELDS.items():
                data[api_field] = form_field in request.form

            user = session.get('user') or {}
            data['updatedBy'] = user.get('preferred_username') or user.get('name')

            try:
                response = requests.post(f"{API_URL}/hosts/settings/update", headers=headers, json=data)

                if response.status_code == 400:
                    flash(_error_message(response, "The settings were rejected."), "danger")
                    return redirect(url_for('host_settings'))

                response.raise_for_status()
                flash(
                    "Host settings saved. Linux hosts pick these up on their next reconcile run, "
                    "or use Apply Now to push immediately.",
                    "success"
                )
            except requests.exceptions.RequestException as e:
                flash("Unable to save host settings. Please try again later.", "danger")
                logger.error(f"Error saving host settings: {e}")

            return redirect(url_for('host_settings'))

        try:
            settings = _load_settings(headers)
        except requests.exceptions.RequestException as e:
            flash("Unable to retrieve host settings. Please try again later.", "danger")
            logger.error(f"Error retrieving host settings: {e}")
            return redirect(url_for('index'))

        hosts = _load_hosts(headers)

        return render_template('settings/host_settings.html', settings=settings, hosts=hosts)

    @app.route('/settings/hosts/apply', methods=['POST'])
    @login_required
    def apply_host_settings():
        headers = _headers()
        if not headers:
            return redirect(url_for('login'))

        hostname = request.form.get('hostname')
        payload = {'hostnames': [hostname]} if hostname else {}

        try:
            response = requests.post(f"{API_URL}/hosts/settings/apply", headers=headers, json=payload)
            response.raise_for_status()
            result = response.json()

            target_count = result.get('TargetCount', 0)
            succeeded = result.get('SucceededCount', 0)

            if target_count == 0:
                flash(
                    "No reachable Linux hosts were found to push to. Hosts still converge on "
                    "their own at their next reconcile run.",
                    "info"
                )
            elif succeeded == target_count:
                flash(f"Applied settings to {succeeded} of {target_count} host(s).", "success")
            else:
                failed = [r.get('Hostname') for r in result.get('Results', []) if not r.get('Applied')]
                flash(
                    f"Applied settings to {succeeded} of {target_count} host(s). "
                    f"Unreachable: {', '.join(filter(None, failed))}. These converge on their next reconcile run.",
                    "warning"
                )
        except requests.exceptions.RequestException as e:
            flash("Unable to push host settings. Please try again later.", "danger")
            logger.error(f"Error pushing host settings: {e}")

        return redirect(url_for('host_settings'))


def _error_message(response, fallback):
    try:
        return response.json().get('error') or fallback
    except ValueError:
        return fallback
