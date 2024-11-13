import requests
import logging

from flask import request, redirect, url_for, session, render_template, flash
from datetime import datetime
from function_authentication import login_required
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
            try:
                startdate = request.form.get('startdate')
                enddate = request.form.get('enddate')
                limit = request.form.get('limit', 'null')

                ignore_dates = request.form.get('ignore_dates')
                ignore_limit = request.form.get('ignore_limit')

                logger.debug("Form data - StartDate: %s, EndDate: %s, Limit: %s", startdate, enddate, limit)
                logger.debug("Flags - Ignore Dates: %s, Ignore Limit: %s", ignore_dates, ignore_limit)

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
                            return redirect(url_for('scaling_activity_log'))
                    else:
                        startdate = "null"

                    if enddate:
                        try:
                            enddate = datetime.strptime(enddate, '%Y-%m-%d').strftime('%m/%d/%Y')
                        except ValueError:
                            flash("Invalid end date format. Please use 'YYYY-MM-DD'.", "danger")
                            return redirect(url_for('scaling_activity_log'))
                    else:
                        enddate = "null"

                data = {
                    "startdate": startdate,
                    "enddate": enddate,
                    "limit": limit if limit else "null"
                }

                logger.debug("Data for API request: %s", data)

                session['scaling_activity_log_data'] = data

                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}

                response = requests.post(f"{API_URL}/scaling/log", headers=headers, json=data)
                response.raise_for_status()

                log = response.json()

                if not log:
                    flash("No scaling activities found for the specified criteria.", "info")
                else:
                    flash("Scaling activity log retrieved successfully!", "success")

                session['scaling_activity_log'] = log

                return redirect(url_for('scaling_activity_log'))
            except requests.exceptions.RequestException as e:
                flash("Unable to retrieve scaling activity log. Please try again later.", "danger")
                logger.error("Failed to retrieve scaling activity log: %s", e)
                return redirect(url_for('view_all_rules'))
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error("Unexpected error in scaling_activity_log POST: %s", e)
                return redirect(url_for('view_all_rules'))
        else:
            try:
                log = session.get('scaling_activity_log', [])
                page = max(1, int(request.args.get('page', 1)))
                per_page = max(1, int(request.args.get('per_page', 10)))
                total_items = len(log)
                total_pages = (total_items + per_page - 1) // per_page

                start = (page - 1) * per_page
                end = start + per_page
                log_paginated = log[start:end]

                logger.debug("Page: %s, Per Page: %s, Total Pages: %s", page, per_page, total_pages)
                logger.debug("Log items displayed: %s", len(log_paginated))

                return render_template('scaling/scaling_activity_log.html',
                                       log=log_paginated,
                                       page=page,
                                       total_pages=total_pages,
                                       per_page=per_page)
            except Exception as e:
                flash("An unexpected error occurred while displaying scaling activity log.", "danger")
                logger.error("Unexpected error in scaling_activity_log GET: %s", e)
                return redirect(url_for('view_all_rules'))

    @app.route('/scaling/rules/history', methods=['GET', 'POST'])
    @login_required
    def scaling_rules_history():
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
                            return redirect(url_for('scaling_rules_history'))
                    else:
                        startdate = "null"

                    if enddate:
                        try:
                            enddate = datetime.strptime(enddate, '%Y-%m-%d').strftime('%m/%d/%Y')
                        except ValueError:
                            flash("Invalid end date format. Please use 'YYYY-MM-DD'.", "danger")
                            return redirect(url_for('scaling_rules_history'))
                    else:
                        enddate = "null"

                data = {
                    "startdate": startdate,
                    "enddate": enddate,
                    "limit": limit if limit else "null"
                }

                session['scaling_rules_history_data'] = data

                access_token = session.get("access_token")
                if not access_token:
                    return redirect(url_for('login'))
                headers = {'Authorization': f'Bearer {access_token}'}

                response = requests.post(f"{API_URL}/scaling/rules/history", headers=headers, json=data)
                response.raise_for_status()

                history = response.json()

                if not history:
                    flash("No scaling rules history found for the specified criteria.", "info")
                else:
                    flash("Scaling rules history retrieved successfully!", "success")

                session['scaling_rules_history'] = history

                return redirect(url_for('scaling_rules_history'))
            except requests.exceptions.RequestException as e:
                flash("Unable to retrieve scaling rules history. Please try again later.", "danger")
                logger.error("Failed to retrieve scaling rules history: %s", e)
                return redirect(url_for('view_all_rules'))
            except Exception as e:
                flash("An unexpected error occurred. Please try again later.", "danger")
                logger.error("Unexpected error in scaling_rules_history POST: %s", e)
                return redirect(url_for('view_all_rules'))
        else:
            try:
                history = session.get('scaling_rules_history', [])
                page = max(1, int(request.args.get('page', 1)))
                per_page = max(1, int(request.args.get('per_page', 10)))
                total_items = len(history)
                total_pages = (total_items + per_page - 1) // per_page

                start = (page - 1) * per_page
                end = start + per_page
                history_paginated = history[start:end]

                logger.debug("Page: %s, Per Page: %s, Total Pages: %s", page, per_page, total_pages)
                logger.debug("History items displayed: %s", len(history_paginated))

                return render_template('scaling/scaling_rules_history.html',
                                       history=history_paginated,
                                       page=page,
                                       total_pages=total_pages,
                                       per_page=per_page)
            except Exception as e:
                flash("An unexpected error occurred while displaying scaling rules history.", "danger")
                logger.error("Unexpected error in scaling_rules_history GET: %s", e)
                return redirect(url_for('view_all_rules'))
