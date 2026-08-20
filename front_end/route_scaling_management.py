import requests
import logging

from flask import request, redirect, url_for, session, render_template, flash
from datetime import datetime
from function_authentication import login_required
from function_api import NotAuthenticated, fetch_history_page
from config import API_URL

logger = logging.getLogger(__name__)

def register_route_scaling_management(app):
    @app.route('/scaling/rules')
    @login_required
    def view_all_rules():
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.get(f"{API_URL}/scaling/rules", headers=headers)
            response.raise_for_status()
            rules = response.json()
            return render_template('scaling/view_all_rules.html', rules=rules)
        except requests.exceptions.RequestException as e:
            flash("Unable to retrieve scaling rules. Please try again later.", "danger")
            logger.error("Failed to retrieve scaling rules: %s", e)
            return redirect(url_for('index'))

    @app.route('/scaling/rules/<int:ruleid>')
    @login_required
    def view_rule_details(ruleid):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.get(f"{API_URL}/scaling/rules/{ruleid}", headers=headers)
            response.raise_for_status()
            rule = response.json()
            return render_template('scaling/view_rule_details.html', rule=rule)
        except requests.exceptions.RequestException as e:
            flash("Unable to retrieve scaling rule details. Please try again later.", "danger")
            logger.error("Failed to retrieve scaling rule details for RuleID %s: %s", ruleid, e)
            return redirect(url_for('view_all_rules'))

    @app.route('/scaling/rules/create', methods=['GET', 'POST'])
    @login_required
    def create_rule():
        if request.method == 'POST':
            try:
                data = {
                    "minvms": request.form['minvms'],
                    "maxvms": request.form['maxvms'],
                    "scaleupratio": request.form['scaleupratio'],
                    "scaleupincrement": request.form['scaleupincrement'],
                    "scaledownratio": request.form['scaledownratio'],
                    "scaledownincrement": request.form['scaledownincrement']
                }
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.post(f"{API_URL}/scaling/rules/create", headers=headers, json=data)
                if response.status_code == 201:
                    flash("Scaling rule created successfully!", "success")
                    return redirect(url_for('view_all_rules'))
                else:
                    flash(f"Unexpected error occurred: {response.status_code} - {response.text}", "danger")
                    logger.error("Unexpected error creating scaling rule: %s - %s", response.status_code, response.text)
            except requests.exceptions.RequestException as e:
                flash("Unable to create scaling rule. Please try again later.", "danger")
                logger.error("Failed to create scaling rule: %s", e)
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error("Unexpected error in create_rule: %s", e)
        return render_template('scaling/create_rule.html')

    @app.route('/scaling/rules/<int:ruleid>/update', methods=['GET', 'POST'])
    @login_required
    def update_rule(ruleid):
        if request.method == 'POST':
            try:
                data = {
                    "minvms": request.form['minvms'],
                    "maxvms": request.form['maxvms'],
                    "scaleupratio": request.form['scaleupratio'],
                    "scaleupincrement": request.form['scaleupincrement'],
                    "scaledownratio": request.form['scaledownratio'],
                    "scaledownincrement": request.form['scaledownincrement']
                }
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.post(f"{API_URL}/scaling/rules/{ruleid}/update", headers=headers, json=data)
                response.raise_for_status()
                flash("Scaling rule updated successfully!", "success")
                return redirect(url_for('view_rule_details', ruleid=ruleid))
            except requests.exceptions.RequestException as e:
                flash("Unable to update scaling rule. Please try again later.", "danger")
                logger.error("Failed to update scaling rule %s: %s", ruleid, e)
                return redirect(url_for('view_rule_details', ruleid=ruleid))
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error("Unexpected error in update_rule POST: %s", e)
        else:
            try:
                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}
                response = requests.get(f"{API_URL}/scaling/rules/{ruleid}", headers=headers)
                response.raise_for_status()
                rule = response.json()
                return render_template('scaling/update_rule.html', rule=rule)
            except requests.exceptions.RequestException as e:
                flash("Unable to retrieve scaling rule details. Please try again later.", "danger")
                logger.error("Failed to retrieve scaling rule details for RuleID %s: %s", ruleid, e)
                return redirect(url_for('view_all_rules'))
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error("Unexpected error in update_rule GET: %s", e)

    @app.route('/scaling/rules/<int:ruleid>/delete', methods=['POST'])
    @login_required
    def delete_rule(ruleid):
        try:
            access_token = session.get("access_token")
            if not access_token:
                return redirect(url_for('login'))
            headers = {'Authorization': f'Bearer {access_token}'}
            response = requests.post(f"{API_URL}/scaling/rules/{ruleid}/delete", headers=headers)
            response.raise_for_status()
            flash("Scaling rule deleted successfully!", "success")
        except requests.exceptions.RequestException as e:
            flash("Unable to delete scaling rule. Please try again later.", "danger")
            logger.error("Failed to delete scaling rule %s: %s", ruleid, e)
        except Exception as e:
            flash("An unexpected error occurred. Please try again later.", "danger")
            logger.error("Unexpected error in delete_rule: %s", e)
        return redirect(url_for('view_all_rules'))

    @app.route('/scaling/log', methods=['GET', 'POST'])
    @login_required
    def scaling_activity_log():
        if request.method == 'POST':
            startdate = request.form.get('startdate')
            enddate = request.form.get('enddate')
            limit = request.form.get('limit', '')

            ignore_dates = request.form.get('ignore_dates')
            ignore_limit = request.form.get('ignore_limit')

            # Validate up front so a bad date is reported against the form the operator
            # is looking at rather than failing later inside the query.
            if not ignore_dates:
                for label, value in (("start", startdate), ("end", enddate)):
                    if not value:
                        continue
                    try:
                        datetime.strptime(value, '%Y-%m-%d')
                    except ValueError:
                        flash(f"Invalid {label} date format. Please use 'YYYY-MM-DD'.", "danger")
                        return redirect(url_for('scaling_activity_log'))

            # Only the criteria live in the session now; each page is fetched from the
            # API on the GET, so the session cannot grow without bound and two tabs
            # cannot overwrite each other's results.
            session['scaling_activity_log_filters'] = {
                "startdate": startdate or "",
                "enddate": enddate or "",
                "limit": limit if limit and limit != "null" else "",
                "ignore_dates": bool(ignore_dates),
                "ignore_limit": bool(ignore_limit),
            }
            session.pop('scaling_activity_log', None)
            session.pop('scaling_activity_log_data', None)

            return redirect(url_for('scaling_activity_log'))

        filters = session.get('scaling_activity_log_filters') or {
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
                '/scaling/log', filters, page, per_page
            )
        except NotAuthenticated:
            return redirect(url_for('login'))
        except (requests.exceptions.RequestException, ValueError) as e:
            flash("Unable to retrieve the scaling activity log. Please try again later.", "danger")
            logger.error("Error retrieving scaling activity log: %s", e)
            return redirect(url_for('view_all_rules'))

        return render_template('scaling/scaling_activity_log.html',
                               log=rows,
                               page=page,
                               total_pages=total_pages,
                               per_page=per_page,
                               total_items=total_items,
                               filters=filters)

    @app.route('/scaling/rules/history', methods=['GET', 'POST'])
    @login_required
    def scaling_rules_history():
        if request.method == 'POST':
            startdate = request.form.get('startdate')
            enddate = request.form.get('enddate')
            limit = request.form.get('limit', '')

            ignore_dates = request.form.get('ignore_dates')
            ignore_limit = request.form.get('ignore_limit')

            # Validate up front so a bad date is reported against the form the operator
            # is looking at rather than failing later inside the query.
            if not ignore_dates:
                for label, value in (("start", startdate), ("end", enddate)):
                    if not value:
                        continue
                    try:
                        datetime.strptime(value, '%Y-%m-%d')
                    except ValueError:
                        flash(f"Invalid {label} date format. Please use 'YYYY-MM-DD'.", "danger")
                        return redirect(url_for('scaling_rules_history'))

            # Only the criteria live in the session now; each page is fetched from the
            # API on the GET, so the session cannot grow without bound and two tabs
            # cannot overwrite each other's results.
            session['scaling_rules_history_filters'] = {
                "startdate": startdate or "",
                "enddate": enddate or "",
                "limit": limit if limit and limit != "null" else "",
                "ignore_dates": bool(ignore_dates),
                "ignore_limit": bool(ignore_limit),
            }
            session.pop('scaling_rules_history', None)
            session.pop('scaling_rules_history_data', None)

            return redirect(url_for('scaling_rules_history'))

        filters = session.get('scaling_rules_history_filters') or {
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
                '/scaling/rules/history', filters, page, per_page
            )
        except NotAuthenticated:
            return redirect(url_for('login'))
        except (requests.exceptions.RequestException, ValueError) as e:
            flash("Unable to retrieve the scaling rules history. Please try again later.", "danger")
            logger.error("Error retrieving scaling rules history: %s", e)
            return redirect(url_for('view_all_rules'))

        return render_template('scaling/scaling_rules_history.html',
                               history=rows,
                               page=page,
                               total_pages=total_pages,
                               per_page=per_page,
                               total_items=total_items,
                               filters=filters)
