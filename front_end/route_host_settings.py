import logging

import requests
from flask import request, redirect, url_for, session, render_template, flash

from function_api import NotAuthenticated, api_get, api_post
from function_authentication import login_required

logger = logging.getLogger(__name__)

# Form field name -> API payload field. Keeping this in one place means the form, the submit
# handler, and the template stay in step.
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
    @app.route('/settings/hosts', methods=['GET', 'POST'])
    @login_required
    def host_settings():
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

            # Unchecked boxes are absent from the form, so they must be sent explicitly as
            # false rather than omitted, which the API would read as "leave unchanged".
            for form_field, api_field in BOOLEAN_FIELDS.items():
                data[api_field] = form_field in request.form

            user = session.get('user') or {}
            data['updatedBy'] = user.get('preferred_username') or user.get('name')

            try:
                api_post('/hosts/settings/update', data)
                flash(
                    "Host settings saved. Linux hosts pick these up on their next reconcile run, "
                    "or use Apply Now to push immediately.",
                    "success"
                )
            except NotAuthenticated:
                return redirect(url_for('login'))
            except requests.exceptions.HTTPError as e:
                response = getattr(e, 'response', None)
                # The API explains exactly which value was rejected, which is far more useful
                # to an admin than a generic failure message.
                if response is not None and response.status_code == 400:
                    flash(_error_message(response, "The settings were rejected."), "danger")
                else:
                    flash("Unable to save host settings. Please try again later.", "danger")
                    logger.error("Error saving host settings: %s", e)
            except (requests.exceptions.RequestException, ValueError) as e:
                flash("Unable to save host settings. Please try again later.", "danger")
                logger.error("Error saving host settings: %s", e)

            return redirect(url_for('host_settings'))

        try:
            settings = api_get('/hosts/settings')
        except NotAuthenticated:
            return redirect(url_for('login'))
        except (requests.exceptions.RequestException, ValueError) as e:
            flash("Unable to retrieve host settings. Please try again later.", "danger")
            logger.error("Error retrieving host settings: %s", e)
            return redirect(url_for('index'))

        # A failure here must not hide the settings form, so the drift table degrades to empty
        # rather than taking the whole page down.
        try:
            hosts = api_get('/vms')
        except (NotAuthenticated, requests.exceptions.RequestException, ValueError) as e:
            hosts = []
            logger.warning("Unable to load hosts for the settings drift table: %s", e)

        return render_template('settings/host_settings.html', settings=settings, hosts=hosts)

    @app.route('/settings/hosts/apply', methods=['POST'])
    @login_required
    def apply_host_settings():
        hostname = request.form.get('hostname')
        payload = {'hostnames': [hostname]} if hostname else {}

        try:
            result = api_post('/hosts/settings/apply', payload)

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
                    f"Unreachable: {', '.join(filter(None, failed))}. "
                    "These converge on their next reconcile run.",
                    "warning"
                )
        except NotAuthenticated:
            return redirect(url_for('login'))
        except (requests.exceptions.RequestException, ValueError) as e:
            flash("Unable to push host settings. Please try again later.", "danger")
            logger.error("Error pushing host settings: %s", e)

        return redirect(url_for('host_settings'))


def _error_message(response, fallback):
    try:
        return response.json().get('error') or fallback
    except ValueError:
        return fallback
