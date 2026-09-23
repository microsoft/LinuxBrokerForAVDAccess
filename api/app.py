import os
import json
import subprocess
import pymssql
import secrets
import string
import time
import threading
import logging
import re
import shlex
import uuid

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.api')

from flask import Flask, g, jsonify, request
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from functools import wraps
from contextlib import contextmanager
from azure.keyvault.secrets import SecretClient
from config import *
from authorization import (
    AuthenticationError, AuthenticationUnavailable, Policy, PrincipalKind, authenticate,
)

# ===============================
# Flask App

app = Flask(__name__)
app.config['VERSION'] = '0.159'

REMOTE_CREATE_USER_SCRIPT = '/usr/local/bin/create-user.sh'
REMOTE_MANAGE_LEASE_SCRIPT = '/usr/local/bin/manage-lease.sh'
REMOTE_APPLY_SETTINGS_SCRIPT = '/usr/local/bin/apply-host-settings.sh'

# ===============================
# Logging Configuration

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('linuxbroker.api')


@app.route('/health', methods=['GET'])
def health():
    try:
        with db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT 1')
            cursor.fetchone()
        return jsonify({'status': 'healthy', 'version': app.config['VERSION']}), 200
    except DatabaseUnavailable:
        logger.error("Database connection failed during health check.")
        return jsonify({'status': 'unhealthy'}), 503
    except Exception:
        logger.exception("Health check failed.")
        return jsonify({'status': 'unhealthy'}), 503

# ===============================
# Functions

def retrieve_db_password_from_key_vault():
    global db_password
    try:
        credential = DefaultAzureCredential()
        secret_client = SecretClient(vault_url=VAULT_URL, credential=credential)
        secret = secret_client.get_secret(DB_PASSWORD_NAME)
        db_password = secret.value
    except Exception as e:
        logger.error("Error retrieving password from Key Vault: %s", e)
        db_password = None

def get_db_connection():
    global db_password
    if db_password is None:
        retrieve_db_password_from_key_vault()
        if db_password is None:
            logger.error("Cannot connect to database without a password.")
            return None
    try:
        conn = pymssql.connect(
            server=DB_SERVER,
            user=DB_USERNAME,
            password=db_password,
            database=DB_DATABASE
        )
        return conn
    except pymssql.Error as e:
        logger.error("Error connecting to database: %s", e)
        return None

def refresh_db_password(interval=3600):
    while True:
        time.sleep(interval)
        retrieve_db_password_from_key_vault()

def retrieve_pem_key_from_key_vault(vault_url, key_name):
    credential = DefaultAzureCredential()
    secret_client = SecretClient(vault_url=vault_url, credential=credential)
    secret = secret_client.get_secret(key_name)
    pem_key = secret.value.replace('\\n', '\n').replace('\\', '')
    pem_file_path = '/tmp/private_key.pem'
    required_permissions = 0o600

    if not os.path.exists(pem_file_path):
        try:
            with open(pem_file_path, 'w') as pem_file:
                pem_file.write(pem_key)
            os.chmod(pem_file_path, required_permissions)
        except Exception as e:
            logger.error("Failed to write PEM key to file: %s", e)
            raise
    else:
        current_permissions = oct(os.stat(pem_file_path).st_mode & 0o777)
        if int(current_permissions, 8) != required_permissions:
            try:
                os.chmod(pem_file_path, required_permissions)
            except Exception as e:
                logger.error("Failed to update permissions for %s: %s", pem_file_path, e)
                raise

    return pem_file_path

def normalize_lease_id(value):
    if not isinstance(value, (str, uuid.UUID)):
        return None
    try:
        parsed = uuid.UUID(str(value))
        return str(parsed) if parsed.int and str(parsed) == str(value).lower() else None
    except (ValueError, TypeError, AttributeError):
        return None

def serialize_for_json(value):
    if isinstance(value, uuid.UUID):
        return str(value)

    if isinstance(value, dict):
        if 'LeaseGeneration' in value:
            generation = value['LeaseGeneration']
            if type(generation) is not int or not 0 <= generation <= MAX_LEASE_GENERATION:
                raise ValueError("Stored lease generation is outside the shared JSON integer range.")
        return {key: serialize_for_json(item) for key, item in value.items()}

    if isinstance(value, list):
        return [serialize_for_json(item) for item in value]

    return value


# ===============================
# Request plumbing


class DatabaseUnavailable(Exception):
    """The API could not obtain a database connection."""


@contextmanager
def db_connection():
    """Yield a database connection that is always closed.

    Most handlers previously called get_db_connection() and then conn.close() on the
    success path only, so any exception in between leaked the connection until the
    pool was exhausted. Using this as a context manager makes the close unconditional.

    Raises DatabaseUnavailable when a connection cannot be established, so callers do
    not have to repeat the `if not conn` check.
    """
    conn = get_db_connection()
    if not conn:
        raise DatabaseUnavailable("Could not establish a database connection.")
    try:
        yield conn
    finally:
        try:
            conn.close()
        except Exception:
            logger.exception("Failed to close database connection.")


def error_response(message, status=500):
    """Return a consistent JSON error envelope.

    Handlers used to return the raw str(e), which exposed driver errors, server names
    and schema details to the caller. The detail belongs in Application Insights, not
    in the response body.
    """
    return jsonify({'error': message}), status


def coerce_optional_int(value, default=None, minimum=None, maximum=None):
    """Parse an optional integer that may arrive as the string 'null'.

    The portal sends the literal string "null" for an unset limit. The stored
    procedures declare @Limit as INT, so passing that string through made SQL Server
    fail converting 'null' to int and the request 500'd -- which is why the portal's
    "No Limit" option never worked. Anything unparseable is treated as unset rather
    than as an error, so an old portal build keeps working during a rolling upgrade.
    """
    if value is None:
        return default

    if isinstance(value, bool):
        return default

    if isinstance(value, str):
        candidate = value.strip()
        if candidate == '' or candidate.lower() in ('null', 'none', 'undefined'):
            return default
    else:
        candidate = value

    try:
        parsed = int(candidate)
    except (TypeError, ValueError):
        return default

    if minimum is not None and parsed < minimum:
        return minimum
    if maximum is not None and parsed > maximum:
        return maximum
    return parsed


def normalize_date_filter(value):
    """Treat the portal's 'null' sentinel and blank strings as 'no filter'."""
    if value is None:
        return None
    if isinstance(value, str):
        candidate = value.strip()
        if candidate == '' or candidate.lower() in ('null', 'none'):
            return None
        return candidate
    return value


# Matches the clamp inside the paged stored procedures.
MAX_PAGE_SIZE = 200
DEFAULT_PAGE_SIZE = 50


def run_history_query(proc, paged_proc, label):
    """Shared implementation for the three date-filtered history endpoints.

    Pagination is opt-in: when neither `page` nor `per_page` is supplied the response
    stays a bare JSON array, because the scheduled task and older portal builds consume
    these endpoints as plain lists.
    """
    try:
        req_body = request.get_json(silent=True) or {}

        startdate = normalize_date_filter(req_body.get('startdate'))
        enddate = normalize_date_filter(req_body.get('enddate'))

        raw_page = request.args.get('page', req_body.get('page'))
        raw_per_page = request.args.get('per_page', req_body.get('per_page'))
        wants_pagination = raw_page is not None or raw_per_page is not None

        if wants_pagination:
            page = coerce_optional_int(raw_page, default=1, minimum=1)
            per_page = coerce_optional_int(
                raw_per_page, default=DEFAULT_PAGE_SIZE, minimum=1, maximum=MAX_PAGE_SIZE
            )
            offset = (page - 1) * per_page

            # The paged procedures have no @Limit, so an operator-supplied limit is
            # applied here as a cap on the overall result set. Without this the limit
            # box in the portal would silently do nothing once paging was enabled.
            limit = coerce_optional_int(req_body.get('limit'), default=None, minimum=1)

            with db_connection() as conn:
                with conn.cursor(as_dict=True) as cursor:
                    cursor.execute(
                        f"EXEC {paged_proc} @StartDate = %s, @EndDate = %s, @Offset = %s, @PageSize = %s",
                        (startdate, enddate, offset, per_page),
                    )
                    rows = cursor.fetchall() or []

                    # TotalCount rides along on each row, so an out-of-range page
                    # returns nothing and the total would otherwise read as 0 --
                    # making "page 40 of 4" indistinguishable from "no matches" and
                    # collapsing the pager so the operator cannot navigate back.
                    if not rows and offset > 0:
                        cursor.execute(
                            f"EXEC {paged_proc} @StartDate = %s, @EndDate = %s, @Offset = %s, @PageSize = %s",
                            (startdate, enddate, 0, 1),
                        )
                        probe = cursor.fetchall() or []
                        total = int(probe[0].get('TotalCount') or 0) if probe else 0
                    else:
                        total = int(rows[0].get('TotalCount') or 0) if rows else 0

            items = [
                {key: value for key, value in row.items() if key != 'TotalCount'}
                for row in rows
            ]

            if limit is not None:
                total = min(total, limit)
                remaining = max(0, limit - offset)
                items = items[:remaining]

            total_pages = (total + per_page - 1) // per_page if per_page else 0

            return jsonify(serialize_for_json({
                'items': items,
                'page': page,
                'per_page': per_page,
                'total': total,
                'total_pages': total_pages,
            })), 200

        # Unpaged path. `limit` may arrive as the string "null" from the portal.
        limit = coerce_optional_int(req_body.get('limit'), default=None, minimum=1)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    f"EXEC {proc} @StartDate = %s, @EndDate = %s, @Limit = %s",
                    (startdate, enddate, limit),
                )
                rows = cursor.fetchall() or []

        return jsonify(serialize_for_json(rows)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while reading %s.", label)
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to read %s.", label)
        return error_response(f"Unable to retrieve the {label}.", 500)

def get_remote_host_fqdn(hostname: str) -> str:
    linux_host_admin_login_name = LINUX_HOST_ADMIN_LOGIN_NAME or 'avdadmin'
    return f"{linux_host_admin_login_name}@{hostname}.{DOMAIN_NAME}"

def run_remote_command(hostname: str, command: str, stdin_input: str = None, timeout: int = 120):
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)
    host_fqdn = get_remote_host_fqdn(hostname)
    result = subprocess.run(
        [
            'ssh',
            '-i', pem_file_path,
            '-o', 'StrictHostKeyChecking=no',
            # Without these, a powered-off or wedged host blocks the worker indefinitely.
            # That matters most for fleet-wide settings pushes, which iterate every host.
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=10',
            host_fqdn,
            command
        ],
        capture_output=True,
        text=True,
        input=stdin_input,
        timeout=timeout
    )
    return result, host_fqdn

def generate_secure_password(length=25) -> str:
    characters = string.ascii_letters + string.digits + string.punctuation.replace(':', '')
    password = ''.join(secrets.choice(characters) for _ in range(length))
    return password


def audit(action, outcome, resource=None):
    principal = getattr(g, 'principal', None)
    logger.info("broker_decision %s", json.dumps({
        'action': action, 'outcome': outcome, 'resource': resource,
        'tenant': principal.tenant_id if principal else None,
        'actor': principal.object_id if principal else None,
        'principalType': principal.kind.value if principal else None,
    }, sort_keys=True))


def call_procedure(name, *, all_rows=False, **parameters):
    # Names originate only in broker code; every data value is a bound SQL parameter.
    sql = f"EXEC {name} " + ", ".join(f"@{key} = %s" for key in parameters)
    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute(sql, tuple(parameters.values()))
            result = cursor.fetchall() if all_rows else cursor.fetchone()
        conn.commit()
    return result


def require_policy(policy):
    def decorator(handler):
        @wraps(handler)
        def protected(*args, **kwargs):
            try:
                g.principal = authenticate(request.headers.get('Authorization'))
            except AuthenticationError:
                audit(policy.value, 'unauthenticated')
                return error_response("A valid broker access token is required.", 401)
            except AuthenticationUnavailable:
                logger.error("Broker token verification is temporarily unavailable.")
                return error_response("Authentication is temporarily unavailable.", 503)
            if not g.principal.allows(policy):
                audit(policy.value, 'forbidden')
                return error_response("This principal is not authorized for this operation.", 403)
            if policy in (Policy.HOST, Policy.HOST_SETTINGS) and g.principal.is_workload('LinuxHost'):
                try:
                    host = call_procedure('GetBrokerHost', TenantId=g.principal.tenant_id, ObjectId=g.principal.object_id)
                except (DatabaseUnavailable, pymssql.Error):
                    logger.exception("Unable to verify the registered host binding.")
                    return error_response("Host authorization is temporarily unavailable.", 503)
                requested_host = kwargs.get('hostname')
                if not host or (requested_host and requested_host.lower() != host['Hostname'].lower()):
                    audit(policy.value, 'host_mismatch', requested_host)
                    return error_response("This principal is not authorized for this host.", 403)
                g.registered_hostname = host['Hostname']
            audit(policy.value, 'authorized', kwargs.get('hostname') or kwargs.get('vmid'))
            return handler(*args, **kwargs)
        protected.authorization_policy = policy
        return protected
    return decorator


@app.after_request
def prevent_sensitive_response_caching(response):
    if request.path.startswith('/api/'):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
    return response


def json_object():
    payload = request.get_json(silent=True)
    return payload if isinstance(payload, dict) else None


def lease_guards(payload):
    if payload is None:
        return None
    lease = normalize_lease_id(payload.get('leaseId'))
    generation = payload.get('leaseGeneration')
    if not lease or type(generation) is not int or not 1 <= generation <= MAX_LEASE_GENERATION:
        return None
    return lease, generation


def valid_hostname(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value) is not None


class HostOperationError(Exception):
    """The host did not conclusively acknowledge the reserved operation."""


def run_host_operation(row, password=None):
    lease = normalize_lease_id(row.get('LeaseId'))
    operation = normalize_lease_id(row.get('OperationId'))
    generation = row.get('LeaseGeneration')
    uid = row.get('Uid')
    username = row.get('Username')
    if (not lease or not operation or type(generation) is not int or not 1 <= generation <= MAX_LEASE_GENERATION
            or type(uid) is not int or not 2000 <= uid <= 2147483646 or uid in (65534, 65535)
            or not isinstance(username, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', username)
            or not valid_hostname(row.get('Hostname'))):
        raise HostOperationError("Invalid reserved operation.")
    if password is not None:
        arguments = [REMOTE_CREATE_USER_SCRIPT, NFS_SHARE or '', str(uid), username, lease, str(generation), operation]
        outcomes = {'ready'}
    else:
        arguments = [REMOTE_MANAGE_LEASE_SCRIPT, 'cleanup', username, str(uid), lease, str(generation), operation, row['Reason']]
        outcomes = {'cleaned', 'active', 'disconnected'}
    command = 'sudo -- ' + ' '.join(shlex.quote(arg) for arg in arguments)
    try:
        result, _host = run_remote_command(
            row['Hostname'], command, stdin_input=password + '\n' if password is not None else None,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise HostOperationError("Host command did not complete.") from exc
    if result.returncode != 0:
        raise HostOperationError("Host refused or could not complete the operation.")
    try:
        acknowledgement = json.loads(result.stdout)
    except (ValueError, TypeError) as exc:
        raise HostOperationError("Host acknowledgement was not valid JSON.") from exc
    if (not isinstance(acknowledgement, dict) or not isinstance(acknowledgement.get('outcome'), str)
            or acknowledgement.get('outcome') not in outcomes
            or acknowledgement.get('leaseId') != lease or acknowledgement.get('leaseGeneration') != generation
            or type(acknowledgement.get('leaseGeneration')) is not int
            or acknowledgement.get('operationId') != operation):
        raise HostOperationError("Host acknowledgement did not match the reservation.")
    return acknowledgement['outcome']


def fail_operation(row, code):
    try:
        call_procedure('FailBrokerOperation', VMID=row['VMID'], OperationId=row['OperationId'],
                       LeaseGeneration=row['LeaseGeneration'], ErrorCode=code)
    except (DatabaseUnavailable, pymssql.Error):
        # An unacknowledged SQL write leaves the durable Running guard in place.
        logger.exception("Unable to record operation failure; the reservation remains unavailable.")
    audit('lease_operation', code, row.get('VMID'))


def execute_reserved_operation(row, password=None):
    try:
        outcome = run_host_operation(row, password)
    except HostOperationError:
        # Never compensate a failed reconnect by returning its existing assignment.
        fail_operation(row, 'HostUncertain')
        return None, (jsonify({'error': 'Host operation is incomplete; retry is required.', 'retryable': True}), 503)
    try:
        completed = call_procedure('CompleteBrokerOperation', VMID=row['VMID'], OperationId=row['OperationId'],
                                   LeaseGeneration=row['LeaseGeneration'], Outcome=outcome)
    except (DatabaseUnavailable, pymssql.Error):
        logger.exception("Unable to confirm operation completion; retain the reservation.")
        return None, (jsonify({'error': 'Operation completion is uncertain; retry is required.', 'retryable': True}), 503)
    if not completed or completed.get('Outcome') != 'Ok':
        audit('lease_operation', 'stale_completion', row['VMID'])
        return None, error_response("The operation no longer matches the reservation.", 409)
    audit('lease_operation', outcome, row['VMID'])
    return outcome, None


def cleanup_lease(lease_id, generation, reason, *, vmid=None, hostname=None):
    row = call_procedure(
        'BeginBrokerCleanup', ExpectedLeaseId=lease_id, ExpectedLeaseGeneration=generation, Reason=reason,
        ActorTenantId=g.principal.tenant_id, ActorObjectId=g.principal.object_id, VMID=vmid, Hostname=hostname,
    )
    if not row or row.get('Outcome') != 'Ok':
        audit('cleanup', 'conflict', vmid or hostname)
        return error_response("The lease changed, is busy, or is not eligible for cleanup.", 409)
    outcome, failure = execute_reserved_operation(row)
    if failure is not None:
        return failure
    return jsonify({'status': outcome}), 200

# ===============================
# Linux Host Settings Functions

def normalize_host_settings(row) -> dict:
    """Turn a LinuxHostSettings row into the JSON document the hosts consume."""
    settings = {}

    for field in LINUX_HOST_SETTING_BOUNDS:
        settings[field] = int(row.get(field))

    for field in LINUX_HOST_SETTING_BOOLEANS:
        settings[field] = bool(row.get(field))

    settings['SettingsVersion'] = int(row.get('SettingsVersion'))

    return settings

def validate_host_settings(payload: dict):
    """Validate a settings update, returning (settings, error_message).

    Only known fields are accepted, and every value must already be inside the supported
    range. Values are rejected rather than silently clamped so an admin never believes a
    setting took effect at a value the fleet will not honor.
    """
    if not isinstance(payload, dict):
        return None, 'Settings payload must be a JSON object.'

    known_fields = set(LINUX_HOST_SETTING_BOUNDS) | set(LINUX_HOST_SETTING_BOOLEANS)
    unknown_fields = sorted(set(payload) - known_fields)
    if unknown_fields:
        return None, f"Unknown settings field(s): {', '.join(unknown_fields)}."

    settings = {}

    for field, (minimum, maximum, _default) in LINUX_HOST_SETTING_BOUNDS.items():
        if field not in payload or payload[field] is None:
            continue

        value = payload[field]
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            return None, f"{field} must be an integer."

        try:
            value = int(value)
        except (TypeError, ValueError):
            return None, f"{field} must be an integer."

        if field == 'IdleTimeoutSeconds':
            # 0 disables idle enforcement; any other value must clear the safety floor.
            if value != 0 and not (IDLE_TIMEOUT_MINIMUM_SECONDS <= value <= maximum):
                return None, (
                    f"IdleTimeoutSeconds must be 0 to disable idle enforcement, or between "
                    f"{IDLE_TIMEOUT_MINIMUM_SECONDS} and {maximum} seconds."
                )
        elif not (minimum <= value <= maximum):
            return None, f"{field} must be between {minimum} and {maximum}."

        settings[field] = value

    for field in LINUX_HOST_SETTING_BOOLEANS:
        if field not in payload or payload[field] is None:
            continue

        value = payload[field]
        if isinstance(value, bool):
            settings[field] = value
        elif isinstance(value, int) and value in (0, 1):
            settings[field] = bool(value)
        elif isinstance(value, str) and value.strip().lower() in ('true', 'false', '1', '0'):
            settings[field] = value.strip().lower() in ('true', '1')
        else:
            return None, f"{field} must be a boolean."

    if not settings:
        return None, 'No recognized settings were supplied.'

    return settings, None

def fetch_host_settings():
    """Read the single global settings profile."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetLinuxHostSettings")
                row = cursor.fetchone()

        if not row:
            logger.error("No Linux host settings profile exists.")
            return None

        return normalize_host_settings(row)
    except DatabaseUnavailable:
        logger.error("Database connection failed while reading Linux host settings.")
        return None
    except Exception:
        logger.exception("Error reading Linux host settings.")
        return None

def record_settings_applied(hostname: str, settings_version: int) -> bool:
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC RecordHostSettingsApplied @Hostname = %s, @SettingsVersion = %s",
                    (hostname, settings_version)
                )
                row = cursor.fetchone()

            conn.commit()

        if not row:
            logger.warning("No VM record matched hostname %s while recording applied settings.", hostname)
            return False

        return True
    except DatabaseUnavailable:
        logger.error("Database connection failed while recording applied settings for %s.", hostname)
        return False
    except Exception:
        logger.exception("Error recording applied settings for %s.", hostname)
        return False

def apply_host_settings_to_host(hostname: str, settings: dict):
    """Push settings to one host over SSH.

    The document is written to the remote script's stdin rather than passed on the command
    line, mirroring how the password is delivered to chpasswd. That keeps the values out of
    the remote process list and leaves no shell-injection surface.

    Returns (applied, message) where message is a fixed, non-sensitive summary. Remote stderr
    and exception detail are logged rather than returned, because this value is surfaced in
    an API response.
    """
    try:
        result, host_fqdn = run_remote_command(
            hostname,
            f"sudo {REMOTE_APPLY_SETTINGS_SCRIPT}",
            stdin_input=json.dumps(settings)
        )

        if result.returncode != 0:
            detail = (result.stderr or result.stdout or '').strip()
            logger.error("Failed to apply host settings on '%s': %s", host_fqdn, detail)
            return False, 'The host could not be updated. See the API logs for detail.'

        record_settings_applied(hostname, settings['SettingsVersion'])
        return True, 'Applied.'
    except Exception:
        logger.exception("Error applying host settings on '%s'.", hostname)
        return False, 'The host could not be reached. See the API logs for detail.'

# ===============================
# App Management APIs

@app.route('/api/version', methods=['GET'])
def get_version():
    return jsonify({"version": app.config['VERSION']}), 200


@app.route('/api/me', methods=['GET'])
@require_policy(Policy.CAPABILITIES)
def get_me():
    principal = g.principal
    return jsonify({
        'subject': {'tenantId': principal.tenant_id, 'objectId': principal.object_id},
        'capabilities': {'manage': principal.can_manage, 'connect': principal.can_connect},
    }), 200

# ===============================
# VM Management APIs

@app.route('/api/vms', methods=['GET'])
@require_policy(Policy.INVENTORY)
def get_all_vms():
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                rows = cursor.fetchall()

        if g.principal.kind is PrincipalKind.WORKLOAD:
            fields = ('VMID', 'Hostname', 'IPAddress', 'PowerState', 'NetworkStatus')
            rows = [{field: row.get(field) for field in fields} for row in rows or []]
        return jsonify(serialize_for_json(rows or [])), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while listing VMs.")
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to list VMs.")
        return error_response("Unable to retrieve virtual machines.", 500)

@app.route('/api/vms/summary', methods=['GET'])
@require_policy(Policy.MANAGE)
def get_vm_summary():
    """Aggregate pool counters for the portal dashboard.

    The dashboard previously fetched every VM row over HTTP just to count them, so the
    payload grew with the pool. This returns a fixed-size object computed in SQL.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVmSummary")
                row = cursor.fetchone()

        summary = serialize_for_json(row) if row else {}

        # The procedure always returns a row, but never let the dashboard 500 or render
        # blanks if that ever changes.
        fields = ('TotalVMs', 'Available', 'CheckedOut', 'Maintenance', 'Released',
                  'PoweredOn', 'PoweredOff', 'Unreachable', 'Ready')
        normalized = {field: int(summary.get(field) or 0) for field in fields}

        return jsonify(normalized), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while building the VM summary.")
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to build the VM summary.")
        return error_response("Unable to retrieve the virtual machine summary.", 500)

@app.route('/api/vms/checkout', methods=['POST'])
@require_policy(Policy.CONNECT)
def checkout_vm():
    try:
        payload = json_object()
        if request.args or payload is None or set(payload) != {'avdhost'} or not valid_hostname(payload.get('avdhost')):
            audit('checkout', 'invalid_target')
            return error_response("Supply only avdhost; target identities and lease overrides are not accepted.", 400)
        if not BROKER_CHECKOUT_ENABLED:
            return error_response("Workspace checkout is temporarily paused.", 503)
        if not NFS_SHARE:
            return error_response("Workspace storage is not configured.", 503)
        row = call_procedure('BeginBrokerCheckout', TenantId=g.principal.tenant_id,
                             ObjectId=g.principal.object_id, AvdHost=payload['avdhost'])
        if not row or row.get('Outcome') != 'Ok':
            audit('checkout', 'unavailable')
            return error_response("The workspace is unavailable, busy, or awaiting cleanup. Retry later.", 409)
        password = generate_secure_password()
        _outcome, failure = execute_reserved_operation(row, password)
        if failure is not None:
            return failure
        response = {key: row[key] for key in ('VMID', 'Hostname', 'IPAddress', 'Username', 'LeaseId', 'LeaseGeneration')}
        response['password'] = password
        return jsonify(serialize_for_json(response)), 200
    except (DatabaseUnavailable, pymssql.Error):
        logger.exception("Database operation failed during subject-bound checkout.")
        return error_response("Workspace checkout is temporarily unavailable.", 503)
    except Exception:
        logger.exception("Failed to check out a VM.")
        return error_response("Unable to check out a virtual machine.", 500)

@app.route('/api/vms/<int:vmid>/update-attributes', methods=['POST'])
@require_policy(Policy.MAINTENANCE)
def update_vm_attributes(vmid):
    try:
        req_body = json_object()
        if req_body is None or set(req_body) - {'powerstate', 'networkstatus', 'vmstatus'}:
            return error_response("Supply only powerstate, networkstatus, or vmstatus.", 400)
        powerstate = req_body.get('powerstate')
        networkstatus = req_body.get('networkstatus')
        vmstatus = req_body.get('vmstatus')
        if g.principal.kind is PrincipalKind.WORKLOAD and (powerstate is not None or vmstatus is not None):
            return error_response("Scheduled tasks may update reachability only.", 403)
        if (powerstate is not None and powerstate not in ('On', 'Off')
                or networkstatus is not None and networkstatus not in ('Reachable', 'Unreachable')
                or vmstatus is not None and vmstatus not in ('Available', 'Maintenance')):
            return error_response("Invalid VM attribute; assignment state cannot be set manually.", 400)
        if not any([powerstate, networkstatus, vmstatus]):
            return jsonify({'error': "Please provide at least one attribute to update."}), 400

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC UpdateVmAttributes @VMID = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s",
                    (vmid, powerstate, networkstatus, vmstatus)
                )
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return jsonify({'error': "VM not found or no attributes updated. Please try again."}), 404
        if row.get('Outcome') == 'Conflict':
            return error_response("An owned VM or operation in progress cannot be changed this way.", 409)

        audit('update_vm', 'updated', vmid)
        return jsonify(serialize_for_json(row)), 200

    except json.JSONDecodeError:
        return jsonify({'error': "Invalid JSON data"}), 400

    except DatabaseUnavailable:
        logger.error("Database connection failed while updating VM %s attributes.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to update VM %s attributes.", vmid)
        return error_response("Unable to update virtual machine attributes.", 500)

@app.route('/api/vms/<int:vmid>/delete', methods=['POST'])
@require_policy(Policy.MANAGE)
def delete_vm(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteVm @VMID = %s", (vmid,))
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} could not be deleted or was not found.", 404)
        if row.get('Outcome') == 'Conflict':
            return error_response("Clean up the outstanding assignment before deleting the VM.", 409)

        audit('delete_vm', 'deleted', vmid)
        return f"VM with VMID {vmid} has been successfully deleted.", 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while deleting VM %s.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to delete VM %s.", vmid)
        return error_response("Unable to delete the virtual machine.", 500)

@app.route('/api/vms/add', methods=['POST'])
@require_policy(Policy.MANAGE)
def add_new_vm():
    try:
        req_body = json_object()
        if req_body is None or set(req_body) - {'hostname', 'ipaddress', 'powerstate', 'networkstatus', 'vmstatus', 'description'}:
            return error_response("Assignment and identity fields cannot be supplied when adding a VM.", 400)

        hostname = req_body.get('hostname')
        ipaddress = req_body.get('ipaddress')
        powerstate = req_body.get('powerstate')
        networkstatus = req_body.get('networkstatus')
        vmstatus = req_body.get('vmstatus')
        description = req_body.get('description', None)

        if not (hostname and ipaddress and powerstate and networkstatus and vmstatus):
            return error_response("Please provide 'hostname', 'ipaddress', 'powerstate', 'networkstatus', and 'vmstatus' in the request body.", 400)
        if (not valid_hostname(hostname) or not isinstance(ipaddress, str) or len(ipaddress) > 50
                or powerstate not in ('On', 'Off') or networkstatus not in ('Reachable', 'Unreachable')
                or vmstatus not in ('Available', 'Maintenance')):
            return error_response("Invalid VM inventory fields; only unassigned VMs can be added.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("""
                    EXEC AddVm @Hostname = %s, @IPAddress = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s,
                                @Description = %s
                """, (hostname, ipaddress, powerstate, networkstatus, vmstatus, description))

                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response("Failed to add new VM. Please try again.", 500)

        audit('add_vm', 'added', hostname)
        return jsonify({"NewVMID": row['NewVMID']}), 201

    except json.JSONDecodeError:
        return error_response("Invalid JSON data", 400)

    except DatabaseUnavailable:
        logger.error("Database connection failed while adding a VM.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to add a VM.")
        return error_response("Unable to add the virtual machine.", 500)

@app.route('/api/vms/<int:vmid>', methods=['GET'])
@require_policy(Policy.MANAGE)
def get_vm_details(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVmDetails @VMID = %s", (vmid,))
                row = cursor.fetchone()

        if not row:
            return error_response(f"VM with VMID {vmid} was not found.", 404)

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while reading VM %s.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to read VM %s.", vmid)
        return error_response("Unable to retrieve the virtual machine.", 500)

@app.route('/api/vms/<int:vmid>/return', methods=['POST'])
@require_policy(Policy.MANAGE)
def return_vm(vmid):
    try:
        payload = json_object()
        guards = lease_guards(payload)
        if request.args or not guards or set(payload) != {'leaseId', 'leaseGeneration'}:
            return error_response("A leaseId and integer leaseGeneration are required.", 400)
        return cleanup_lease(*guards, 'admin', vmid=vmid)
    except Exception:
        logger.exception("Failed to return VM %s.", vmid)
        return jsonify({'error': 'Unable to complete the guarded return; retry is required.', 'retryable': True}), 503

@app.route('/api/vms/<hostname>/release', methods=['POST'])
@require_policy(Policy.MANAGE)
def release_vm(hostname):
    try:
        payload = json_object()
        guards = lease_guards(payload)
        if request.args or not guards or set(payload) != {'leaseId', 'leaseGeneration'}:
            return error_response("A leaseId and integer leaseGeneration are required.", 400)
        row = call_procedure('ObserveBrokerSession', Hostname=hostname, LeaseId=guards[0],
                             LeaseGeneration=guards[1], State='disconnected')
        if not row or row.get('Outcome') != 'Ok':
            return error_response("The lease changed or has an operation in progress.", 409)
        audit('admin_release', 'released', hostname)
        return jsonify({'status': 'released'}), 200
    except Exception:
        logger.exception("Failed to record an administrative release.")
        return error_response("Unable to release the virtual machine.", 503)


@app.route('/api/vms/<hostname>/session', methods=['POST'])
@require_policy(Policy.HOST)
def observe_host_session(hostname):
    try:
        payload = json_object()
        guards = lease_guards(payload)
        if (request.args or not guards or set(payload) != {'leaseId', 'leaseGeneration', 'state'}
                or payload.get('state') not in ('active', 'disconnected', 'logged_off')):
            return error_response("Supply leaseId, integer leaseGeneration, and active, disconnected, or logged_off state.", 400)
        row = call_procedure('ObserveBrokerSession', Hostname=g.registered_hostname,
                             LeaseId=guards[0], LeaseGeneration=guards[1], State=payload['state'])
        if not row or row.get('Outcome') != 'Ok':
            audit('session', 'conflict', hostname)
            return error_response("The observation does not match an idle current lease.", 409)
        audit('session', payload['state'], hostname)
        if payload['state'] == 'logged_off':
            return cleanup_lease(*guards, 'logged_off', hostname=g.registered_hostname)
        return jsonify({'status': 'recorded'}), 200
    except Exception:
        logger.exception("Unable to reconcile the host observation.")
        return error_response("Session reconciliation is temporarily unavailable.", 503)


@app.route('/api/vms/released', methods=['POST'])
@require_policy(Policy.MAINTENANCE)
def return_released_vm_api():
    try:
        rows = call_procedure('ReturnReleasedVms', all_rows=True) or []
        results = []
        failed = False
        for row in rows:
            response, status = cleanup_lease(
                row['LeaseId'], row['LeaseGeneration'], row['Reason'], vmid=row['VMID'],
            )
            # A concurrent reconnect is a deferred candidate, not successful reclamation.
            results.append({'VMID': row['VMID'], 'status': response.get_json().get('status', 'deferred' if status == 409 else 'retry_required')})
            failed = failed or status >= 500
        return jsonify({'results': results, 'retryable': failed}), 503 if failed else 200
    except Exception:
        logger.exception("Failed to return released VMs.")
        return jsonify({'error': 'Released VM cleanup is incomplete; retry is required.', 'retryable': True}), 503


@app.route('/api/vms/history', methods=['POST'])
@require_policy(Policy.MANAGE)
def get_vm_history():
    return run_history_query(
        proc='GetVmHistory',
        paged_proc='GetVmHistoryPaged',
        label='VM history',
    )

# ===============================
# Scaling APIs

@app.route('/api/scaling/log', methods=['POST'])
@require_policy(Policy.MANAGE)
def get_scaling_activity_log():
    return run_history_query(
        proc='GetScalingActivityLog',
        paged_proc='GetScalingActivityLogPaged',
        label='scaling activity log',
    )

@app.route('/api/scaling/trigger', methods=['POST'])
@require_policy(Policy.MAINTENANCE)
def trigger_scaling_logic():
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return error_response("Configuration error: missing Azure subscription or resource group.", 500)

        credential = DefaultAzureCredential()
        compute_client = ComputeManagementClient(credential=credential, subscription_id=VM_SUBSCRIPTION_ID)

        rows = call_procedure('TriggerScalingLogic', all_rows=True,
                              ActorTenantId=g.principal.tenant_id, ActorObjectId=g.principal.object_id) or []
        powered_on_vms = []
        powered_off_vms = []
        failed_vms = []

        for row in rows:
            vm_name = row['VMName']
            try:
                if row['ActionType'] == 'PowerOn':
                    poller = compute_client.virtual_machines.begin_start(VM_RESOURCE_GROUP, vm_name)
                    outcome = 'On'
                elif row['ActionType'] == 'PowerOff':
                    poller = compute_client.virtual_machines.begin_power_off(VM_RESOURCE_GROUP, vm_name)
                    outcome = 'Off'
                else:
                    raise ValueError("Unsupported reserved power operation.")
                poller.result(timeout=120)
                if not poller.done():
                    raise TimeoutError("Power operation is still pending.")
                completed = call_procedure('CompleteBrokerOperation', VMID=row['VMID'],
                                           OperationId=row['OperationId'], LeaseGeneration=row['LeaseGeneration'], Outcome=outcome)
                if not completed or completed.get('Outcome') != 'Ok':
                    raise RuntimeError("Power operation completion was not confirmed.")
                (powered_on_vms if outcome == 'On' else powered_off_vms).append(vm_name)
            except Exception:
                logger.exception("Power operation was not confirmed for VM %s.", vm_name)
                fail_operation(row, 'PowerUncertain')
                failed_vms.append(vm_name)

        response_payload = {
            'PoweredOnVMs': powered_on_vms,
            'PoweredOffVMs': powered_off_vms,
            'RetryRequiredVMs': failed_vms,
        }

        return jsonify(response_payload), 503 if failed_vms else 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while triggering scaling logic.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to trigger scaling logic.")
        return error_response("Unable to trigger scaling logic.", 500)

# ===============================
# Scaling Rules APIs

@app.route('/api/scaling/rules', methods=['GET'])
@require_policy(Policy.MANAGE)
def get_scaling_rules():
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetScalingRules")
                rows = cursor.fetchall()

        # An empty rule set is a valid state, not an error. Returning 404 here made the
        # portal raise_for_status(), flash a failure and redirect, so its "no rules"
        # empty state could never render.
        return jsonify(serialize_for_json(rows or [])), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while listing scaling rules.")
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to list scaling rules.")
        return error_response("Unable to retrieve scaling rules.", 500)

@app.route('/api/scaling/rules/<int:ruleid>', methods=['GET'])
@require_policy(Policy.MANAGE)
def get_scaling_rule_details(ruleid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetScalingRuleDetails @RuleID = %s", (ruleid,))
                row = cursor.fetchone()

        if not row:
            return error_response(f"Scaling rule with RuleID {ruleid} was not found.", 404)

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while reading scaling rule %s.", ruleid)
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to read scaling rule %s.", ruleid)
        return error_response("Unable to retrieve the scaling rule.", 500)

@app.route('/api/scaling/rules/create', methods=['POST'])
@require_policy(Policy.MANAGE)
def create_scaling_rule():
    try:
        req_body = request.get_json()

        minvms = req_body.get('minvms')
        maxvms = req_body.get('maxvms')
        scaleupratio = req_body.get('scaleupratio')
        scaleupincrement = req_body.get('scaleupincrement')
        scaledownratio = req_body.get('scaledownratio')
        scaledownincrement = req_body.get('scaledownincrement')

        if not all([minvms is not None, maxvms is not None, scaleupratio is not None, scaleupincrement is not None, scaledownratio is not None, scaledownincrement is not None]):
            return error_response(
                "Please provide all required fields: 'minvms', 'maxvms', 'scaleupratio', "
                "'scaleupincrement', 'scaledownratio', 'scaledownincrement'.",
                400
            )

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    """
                    EXEC CreateScalingRule @MinVMs = %s, @MaxVMs = %s, @ScaleUpRatio = %s, 
                                        @ScaleUpIncrement = %s, @ScaleDownRatio = %s, @ScaleDownIncrement = %s
                    """,
                    (minvms, maxvms, scaleupratio, scaleupincrement, scaledownratio, scaledownincrement),
                )
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response("Failed to create the scaling rule. Please try again.", 500)

        new_rule_id = row.get('NewRuleID')

        return jsonify({"NewRuleID": new_rule_id}), 201

    except json.JSONDecodeError:
        return error_response("Invalid JSON data", 400)

    except DatabaseUnavailable:
        logger.error("Database connection failed while creating a scaling rule.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to create a scaling rule.")
        return error_response("Unable to create the scaling rule.", 500)

@app.route('/api/scaling/rules/<int:ruleid>/update', methods=['POST'])
@require_policy(Policy.MANAGE)
def update_scaling_rule(ruleid):
    try:
        req_body = request.get_json()

        minvms = req_body.get('minvms')
        maxvms = req_body.get('maxvms')
        scaleupratio = req_body.get('scaleupratio')
        scaleupincrement = req_body.get('scaleupincrement')
        scaledownratio = req_body.get('scaledownratio')
        scaledownincrement = req_body.get('scaledownincrement')

        if not any([minvms is not None, maxvms is not None, scaleupratio is not None, scaleupincrement is not None, scaledownratio is not None, scaledownincrement is not None]):
            return error_response("Please provide at least one field to update.", 400)

        with db_connection() as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    EXEC UpdateScalingRule @RuleID = %s, @MinVMs = %s, @MaxVMs = %s, @ScaleUpRatio = %s, 
                                        @ScaleUpIncrement = %s, @ScaleDownRatio = %s, @ScaleDownIncrement = %s
                    """,
                    (ruleid, minvms, maxvms, scaleupratio, scaleupincrement, scaledownratio, scaledownincrement),
                )
            conn.commit()

        return f"Scaling rule with RuleID {ruleid} updated successfully.", 200

    except json.JSONDecodeError:
        return error_response("Invalid JSON data", 400)

    except DatabaseUnavailable:
        logger.error("Database connection failed while updating scaling rule %s.", ruleid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to update scaling rule %s.", ruleid)
        return error_response("Unable to update the scaling rule.", 500)

@app.route('/api/scaling/rules/<int:ruleid>/delete', methods=['POST'])
@require_policy(Policy.MANAGE)
def delete_scaling_rule(ruleid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteScalingRule @RuleID = %s", (ruleid,))
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"Scaling rule with RuleID {ruleid} could not be deleted or was not found.", 404)

        return f"Scaling rule with RuleID {ruleid} has been successfully deleted.", 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while deleting scaling rule %s.", ruleid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to delete scaling rule %s.", ruleid)
        return error_response("Unable to delete the scaling rule.", 500)

@app.route('/api/scaling/rules/history', methods=['POST'])
@require_policy(Policy.MANAGE)
def get_scaling_rules_history():
    return run_history_query(
        proc='GetVMScalingRulesHistory',
        paged_proc='GetVmScalingRulesHistoryPaged',
        label='scaling rules history',
    )

# ===============================
# Linux Host Settings APIs

@app.route('/api/hosts/settings', methods=['GET'])
@require_policy(Policy.HOST_SETTINGS)
def get_host_settings():
    """Return the fleet-wide settings profile.

    This is the pull side of settings delivery. The Linux host agents already hold the
    LinuxHost role, so they can read this with no additional Entra configuration.
    """
    try:
        settings = fetch_host_settings()
        if settings is None:
            return jsonify({'error': 'Unable to read Linux host settings.'}), 500

        return jsonify(settings), 200

    except Exception:
        # Detail goes to Application Insights rather than the response body; returning the
        # exception text would expose internal state to the caller.
        logger.exception("Failed to read Linux host settings.")
        return jsonify({'error': 'Unable to read Linux host settings.'}), 500

@app.route('/api/hosts/settings/update', methods=['POST'])
@require_policy(Policy.MANAGE)
def update_host_settings():
    try:
        payload = json_object()
        updated_by = f"{g.principal.tenant_id}/{g.principal.object_id}"

        settings, error = validate_host_settings(payload)
        if error:
            return jsonify({'error': error}), 400

        # Cross-field rules need the resulting profile, not just the supplied fields, because
        # updates are partial. Checking here turns a CHECK constraint violation into a clean
        # 400 instead of a 500 from SQL.
        current = fetch_host_settings()
        if current is None:
            return jsonify({'error': 'Unable to read Linux host settings.'}), 500

        resulting = dict(current)
        resulting.update(settings)

        if resulting['IdleTimeoutSeconds'] != 0 and resulting['IdleWarningSeconds'] >= resulting['IdleTimeoutSeconds']:
            return jsonify({
                'error': (
                    'IdleWarningSeconds must be less than IdleTimeoutSeconds so users are warned '
                    'before they are disconnected.'
                )
            }), 400

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC UpdateLinuxHostSettings "
                    "@GracePeriodSeconds = %s, @ReconcileIntervalSeconds = %s, "
                    "@WatcherDebounceSeconds = %s, @WatcherSettleSeconds = %s, "
                    "@IdleTimeoutSeconds = %s, @IdleWarningSeconds = %s, "
                    "@ScreenLockEnabled = %s, @DisableLockScreen = %s, "
                    "@ScreenIdleDelaySeconds = %s, "
                    "@ScreenLockDelaySeconds = %s, @ScreenLockSettingsLocked = %s, "
                    "@UpdatedBy = %s",
                    (
                        settings.get('GracePeriodSeconds'),
                        settings.get('ReconcileIntervalSeconds'),
                        settings.get('WatcherDebounceSeconds'),
                        settings.get('WatcherSettleSeconds'),
                        settings.get('IdleTimeoutSeconds'),
                        settings.get('IdleWarningSeconds'),
                        settings.get('ScreenLockEnabled'),
                        settings.get('DisableLockScreen'),
                        settings.get('ScreenIdleDelaySeconds'),
                        settings.get('ScreenLockDelaySeconds'),
                        settings.get('ScreenLockSettingsLocked'),
                        updated_by
                    )
                )
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return jsonify({'error': 'Unable to update Linux host settings.'}), 500

        return jsonify(normalize_host_settings(row)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while updating Linux host settings.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to update Linux host settings.")
        return jsonify({'error': 'Unable to update Linux host settings.'}), 500

@app.route('/api/hosts/settings/apply', methods=['POST'])
@require_policy(Policy.MANAGE)
def apply_host_settings():
    """Push the current settings profile to hosts over SSH.

    This is only the fast path. The host agents converge on their own through the pull
    endpoint, so a host that is unreachable here is not left permanently stale; it simply
    picks the settings up on its next reconcile run.
    """
    try:
        payload = request.get_json(silent=True) or {}
        requested_hostnames = payload.get('hostnames')

        if requested_hostnames is not None and not isinstance(requested_hostnames, list):
            return jsonify({'error': 'hostnames must be a list.'}), 400

        settings = fetch_host_settings()
        if settings is None:
            return jsonify({'error': 'Unable to read Linux host settings.'}), 500

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                vms = cursor.fetchall()

        if requested_hostnames:
            wanted = {str(name).strip().lower() for name in requested_hostnames if str(name).strip()}
            targets = [vm for vm in vms if (vm.get('Hostname') or '').lower() in wanted]
        else:
            # Skip hosts the broker already knows it cannot reach, so one powered-off VM
            # does not slow the whole push down to its connect timeout.
            targets = [
                vm for vm in vms
                if (vm.get('PowerState') or '') == 'On' and (vm.get('NetworkStatus') or '') == 'Reachable'
            ]

        results = []
        succeeded = 0

        for vm in targets:
            hostname = vm.get('Hostname')
            if not hostname:
                continue

            applied, message = apply_host_settings_to_host(hostname, settings)
            if applied:
                succeeded += 1

            results.append({
                'Hostname': hostname,
                'Applied': applied,
                'Message': message
            })

        return jsonify({
            'SettingsVersion': settings['SettingsVersion'],
            'TargetCount': len(results),
            'SucceededCount': succeeded,
            'Results': results
        }), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while pushing Linux host settings.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to push Linux host settings.")
        return jsonify({'error': 'Unable to push Linux host settings.'}), 500

@app.route('/api/hosts/<hostname>/settings/ack', methods=['POST'])
@require_policy(Policy.HOST)
def acknowledge_host_settings(hostname):
    """Record the settings version a host has applied, so the portal can show drift."""
    try:
        payload = json_object()
        if payload is None or set(payload) != {'settingsVersion'}:
            return error_response("Supply only settingsVersion.", 400)
        settings_version = payload['settingsVersion']
        if type(settings_version) is not int or not 1 <= settings_version <= 2147483647:
            return jsonify({'error': 'settingsVersion must be a positive integer.'}), 400

        if not record_settings_applied(hostname, settings_version):
            return jsonify({'error': f"No VM found with Hostname {hostname}."}), 404

        return jsonify({'Hostname': hostname, 'SettingsVersion': settings_version}), 200

    except Exception:
        logger.exception("Failed to record the applied settings version for %s.", hostname)
        return jsonify({'error': 'Unable to record the applied settings version.'}), 500

# ===============================
# Main

password_refresh_thread = threading.Thread(target=refresh_db_password, args=(3600,), daemon=True)
password_refresh_thread.start()

if __name__ == '__main__':
    app.run(debug=True)
