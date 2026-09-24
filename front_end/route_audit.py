"""Audit log endpoints for the React portal."""

import csv
import io
import json
import logging
from datetime import datetime, timezone

from flask import Response, request

from function_authentication import login_required
from function_api import api_get, pagination_from_args
from function_bff import API_PREFIX, broker_endpoint, history_response

logger = logging.getLogger(__name__)

# Query-string filters passed through to GET /api/audit, which validates them.
AUDIT_FILTERS = ('from', 'to', 'actor', 'action', 'targetType', 'target', 'outcome')

EXPORT_PAGE_SIZE = 500
EXPORT_MAX_ROWS = 10000
EXPORT_TIMEOUT_SECONDS = 30

CSV_COLUMNS = (
    ('OccurredAtUtc', 'Occurred (UTC)'),
    ('ActorName', 'Actor'),
    ('ActorOid', 'Actor object ID'),
    ('ActorType', 'Actor type'),
    ('Action', 'Action'),
    ('TargetType', 'Target type'),
    ('TargetId', 'Target'),
    ('Outcome', 'Outcome'),
    ('Detail', 'Detail'),
    ('CorrelationId', 'Correlation ID'),
)

# A cell starting with one of these is evaluated as a formula by spreadsheet applications.
FORMULA_PREFIXES = ('=', '+', '-', '@', '\t', '\r')


def audit_filters(args):
    filters = {}
    for name in AUDIT_FILTERS:
        value = (args.get(name) or '').strip()
        if value:
            filters[name] = value[:256]
    return filters


def csv_cell(value):
    """A CSV cell that a spreadsheet will show as text rather than run as a formula.

    Audit entries contain values that came from users and hosts, such as hostnames and
    sign-in names, so every cell is treated as untrusted.
    """
    if value is None:
        return ''
    text = json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else str(value)
    if text.startswith(FORMULA_PREFIXES):
        text = "'" + text
    return text


def register_route_audit(app):
    @app.route(f'{API_PREFIX}/audit')
    @login_required
    @broker_endpoint("Unable to retrieve the audit log. Please try again later.")
    def ui_audit_log():
        page, per_page = pagination_from_args(request.args, default_per_page=25)
        result = api_get('/audit', params=dict(audit_filters(request.args), page=page, per_page=per_page))
        result = result if isinstance(result, dict) else {}

        return history_response(
            result.get('items') or [],
            page,
            per_page,
            int(result.get('total') or 0),
            int(result.get('total_pages') or 0),
        )

    @app.route(f'{API_PREFIX}/audit/export.csv')
    @login_required
    @broker_endpoint("Unable to export the audit log. Please try again later.")
    def ui_audit_export():
        """Every entry matching the filters, newest first, capped at EXPORT_MAX_ROWS."""
        filters = audit_filters(request.args)
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow([label for _, label in CSV_COLUMNS])

        page = 1
        written = 0
        truncated = False
        while True:
            result = api_get(
                '/audit',
                params=dict(filters, page=page, per_page=EXPORT_PAGE_SIZE),
                timeout=EXPORT_TIMEOUT_SECONDS,
            )
            result = result if isinstance(result, dict) else {}
            items = result.get('items') or []

            for item in items:
                if written >= EXPORT_MAX_ROWS:
                    truncated = True
                    break
                writer.writerow([csv_cell(item.get(key)) for key, _ in CSV_COLUMNS])
                written += 1

            if truncated or not items or page >= int(result.get('total_pages') or 0):
                break
            page += 1

        if truncated:
            logger.info("Audit export stopped at %s rows.", EXPORT_MAX_ROWS)

        filename = f"linuxbroker-audit-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}.csv"
        response = Response(buffer.getvalue(), mimetype='text/csv')
        response.headers['Content-Disposition'] = f'attachment; filename="{filename}"'
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Export-Rows'] = str(written)
        if truncated:
            response.headers['X-Export-Truncated'] = 'true'
        return response
