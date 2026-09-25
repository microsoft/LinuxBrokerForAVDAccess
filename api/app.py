import os
import json
import subprocess
import tempfile
import jwt
import requests
import pymssql
import secrets
import string
import time
import threading
import logging
import re
import shlex
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.api')

from flask import Flask, g, has_app_context, jsonify, request
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from functools import wraps
from contextlib import contextmanager
from flask_caching import Cache
from azure.keyvault.secrets import SecretClient
from config import *

try:
    # Installed with azure-monitor-opentelemetry. The trace id ties an audit entry to the
    # request's logs in Application Insights.
    from opentelemetry import trace as otel_trace
except ImportError:  # pragma: no cover - only when the telemetry package is absent
    otel_trace = None

# ===============================
# Flask App

app = Flask(__name__)
app.config['VERSION'] = '0.165'

# Backs is_member_of_group_cached, which keeps token validation off the Graph API on
# every request.
cache = Cache(app, config={'CACHE_TYPE': 'simple'})

REMOTE_CREATE_USER_SCRIPT = '/usr/local/bin/create-user.sh'
REMOTE_MANAGE_LEASE_SCRIPT = '/usr/local/bin/manage-lease.sh'
REMOTE_APPLY_SETTINGS_SCRIPT = '/usr/local/bin/apply-host-settings.sh'
REMOTE_SESSION_CONTROL_SCRIPT = '/usr/local/bin/session-control.sh'

# Output markers shared with linux_host/manage-lease.sh, linux_host/create-user.sh and the
# delete command below. manage-lease.sh printed cleared-in-use before it learned to keep the
# lease of a signed-in user; both mean the account is still in use.
LEASE_ACTION_CLEARED = '__LEASE_ACTION=cleared__'
LEASE_ACTION_IN_USE = '__LEASE_ACTION=in-use__'
LEASE_ACTION_CLEARED_IN_USE = '__LEASE_ACTION=cleared-in-use__'
HOME_STILL_MOUNTED_MARKER = '__HOME_STILL_MOUNTED__'
USERDEL_FAILED_MARKER = '__USERDEL_FAILED__='
CREATE_USER_RESULT_MARKER = '__CREATE_USER_RESULT=ok__'

# Outcomes of cleaning a returned user off a Linux host.
CLEANUP_COMPLETED = 'Completed'
CLEANUP_IN_USE = 'InUse'
CLEANUP_FAILED = 'Failed'
CLEANUP_SKIPPED = 'Skipped'
CLEANUP_DEFERRED = 'Deferred'
CLEANUP_NOT_REQUIRED = 'NotRequired'

VALID_POWER_STATES = ('On', 'Off')
VALID_NETWORK_STATUSES = ('Reachable', 'Unreachable')
VALID_VM_STATUSES = ('Available', 'CheckedOut', 'Maintenance', 'Released')

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

_credential = None
_credential_lock = threading.Lock()

def get_azure_credential():
    """One credential per process, so its token cache is shared instead of rebuilt per call."""
    global _credential
    with _credential_lock:
        if _credential is None:
            _credential = DefaultAzureCredential()
        return _credential

def retrieve_db_password_from_key_vault():
    global db_password
    try:
        secret_client = SecretClient(vault_url=VAULT_URL, credential=get_azure_credential())
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

def normalize_private_key(value: str) -> str:
    # The deployment hooks store the key with escaped newlines and trim the trailing one, and
    # OpenSSH refuses to load a private key that does not end in a newline.
    pem_key = value.replace('\\n', '\n').replace('\\', '').replace('\r', '')
    if not pem_key.endswith('\n'):
        pem_key += '\n'
    return pem_key

PEM_FILE_PATH = '/tmp/private_key.pem'

_ssh_key_lock = threading.Lock()
_ssh_key_state = {'path': None, 'fetched_at': 0.0}

def retrieve_pem_key_from_key_vault(vault_url, key_name):
    secret_client = SecretClient(vault_url=vault_url, credential=get_azure_credential())
    secret = secret_client.get_secret(key_name)
    pem_key = normalize_private_key(secret.value)

    # Written to a private temporary file and renamed into place, so a concurrent ssh in
    # another thread or worker never reads a partially written or wrongly permissioned key.
    directory = os.path.dirname(PEM_FILE_PATH)
    descriptor, temporary_path = tempfile.mkstemp(dir=directory, prefix='.private_key.')
    try:
        with os.fdopen(descriptor, 'w') as pem_file:
            pem_file.write(pem_key)
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, PEM_FILE_PATH)
    except Exception as e:
        logger.error("Failed to write PEM key to file: %s", e)
        try:
            os.remove(temporary_path)
        except OSError:
            pass
        raise

    return PEM_FILE_PATH

def get_ssh_key_path():
    """Return the SSH private key path, reading Key Vault at most once per cache window.

    Every remote command used to fetch the secret again, which put a Key Vault round trip
    on each of the several SSH calls a checkout makes.
    """
    with _ssh_key_lock:
        path = _ssh_key_state['path']
        age = time.monotonic() - _ssh_key_state['fetched_at']
        if path and age < SSH_KEY_CACHE_SECONDS and os.path.exists(path):
            return path

        path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)
        _ssh_key_state['path'] = path
        _ssh_key_state['fetched_at'] = time.monotonic()
        return path

_graph_token_lock = threading.Lock()
_graph_token_state = {'token': None, 'expires_at': 0.0}

def get_access_token(tenant_id, client_id, client_secret):
    """Client-credentials token for Microsoft Graph, reused until shortly before it expires."""
    with _graph_token_lock:
        if _graph_token_state['token'] and time.monotonic() < _graph_token_state['expires_at']:
            return _graph_token_state['token']

        url = f"{AUTHORITY_HOST}/{tenant_id}/oauth2/v2.0/token"
        headers = {
            "Content-Type": "application/x-www-form-urlencoded"
        }
        data = {
            "client_id": client_id,
            "scope": f"{GRAPH_ENDPOINT}/.default",
            "client_secret": client_secret,
            "grant_type": "client_credentials"
        }

        response = requests.post(url, headers=headers, data=data, timeout=10)
        if response.status_code != 200:
            response.raise_for_status()

        payload = response.json()
        token = payload.get("access_token")
        if token:
            try:
                expires_in = int(payload.get("expires_in") or 0)
            except (TypeError, ValueError):
                expires_in = 0
            # Refresh five minutes early so a token never expires mid-request.
            _graph_token_state['token'] = token
            _graph_token_state['expires_at'] = time.monotonic() + max(0, expires_in - 300)
        return token

def reset_caches():
    """Forget every process-level cache. Used by the tests."""
    with _jwks_lock:
        _jwks_state.update({'keys': None, 'fetched_at': 0.0, 'forced_at': 0.0})
    with _graph_token_lock:
        _graph_token_state.update({'token': None, 'expires_at': 0.0})
    with _ssh_key_lock:
        _ssh_key_state.update({'path': None, 'fetched_at': 0.0})
    cache.clear()

def is_duplicate_key_error(error) -> bool:
    text = str(error)
    return '2627' in text or '2601' in text or 'duplicate key' in text.lower()

def is_missing_procedure_error(error) -> bool:
    text = str(error)
    return '2812' in text or 'Could not find stored procedure' in text

def _legacy_get_or_create_uid(username):
    """The allocator used before GetOrCreateVmUserUid existed.

    Kept for a database that has not been migrated yet. It retries once, because two
    concurrent first logins can compute the same MAX(uid)+1.
    """
    for attempt in range(2):
        try:
            with db_connection() as conn:
                cursor = conn.cursor(as_dict=True)

                cursor.execute("SELECT uid FROM VmUsers WHERE username = %s", (username,))
                result = cursor.fetchone()
                if result:
                    return result['uid']

                # Assign a new UID starting from 2000
                cursor.execute("SELECT MAX(uid) AS max_uid FROM VmUsers")
                max_uid = cursor.fetchone()['max_uid'] or 1999
                new_uid = max_uid + 1

                cursor.execute("INSERT INTO VmUsers (username, uid) VALUES (%s, %s)", (username, new_uid))
                conn.commit()

            return new_uid
        except DatabaseUnavailable:
            raise
        except Exception as e:
            if attempt == 0 and is_duplicate_key_error(e):
                continue
            raise

def get_or_create_uid(username):
    try:
        try:
            with db_connection() as conn:
                with conn.cursor(as_dict=True) as cursor:
                    cursor.execute("EXEC GetOrCreateVmUserUid @Username = %s", (username,))
                    row = cursor.fetchone()
                conn.commit()

            uid = row.get('uid') if row else None
            if isinstance(uid, int):
                return uid

            logger.error("GetOrCreateVmUserUid returned no uid for %s.", username)
            return None
        except DatabaseUnavailable:
            raise
        except Exception as e:
            if not is_missing_procedure_error(e):
                raise
            logger.warning("GetOrCreateVmUserUid is not deployed yet; using the legacy uid allocator.")
            return _legacy_get_or_create_uid(username)
    except DatabaseUnavailable:
        logger.error("Database connection failed while resolving uid for %s", username)
        return None
    except Exception:
        logger.exception("Failed to resolve uid for %s.", username)
        return None

def normalize_lease_id(value):
    if value in (None, ''):
        return None

    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return None

def serialize_for_json(value):
    if isinstance(value, uuid.UUID):
        return str(value)

    if isinstance(value, dict):
        return {key: serialize_for_json(item) for key, item in value.items()}

    if isinstance(value, list):
        return [serialize_for_json(item) for item in value]

    return value


# ===============================
# Request plumbing


class DatabaseUnavailable(Exception):
    """The API could not obtain a database connection."""


class DatabaseBusy(DatabaseUnavailable):
    """Every database slot in this process stayed in use for the whole acquire timeout."""


class GroupCheckUnavailable(Exception):
    """Group membership could not be determined (Graph unreachable, throttled, or
    no token).

    Distinct from "the principal is not a member" so a transient Graph failure is
    never cached as an authorization denial.
    """


# Bounds concurrent SQL connections per worker process, so raising gunicorn's thread count
# cannot exceed the database tier's worker limit during a login storm.
_db_slots = threading.BoundedSemaphore(DB_MAX_CONCURRENCY)


@contextmanager
def db_connection():
    """Yield a database connection that is always closed.

    Most handlers previously called get_db_connection() and then conn.close() on the
    success path only, so any exception in between leaked the connection until the
    pool was exhausted. Using this as a context manager makes the close unconditional.

    Raises DatabaseUnavailable when a connection cannot be established, so callers do
    not have to repeat the `if not conn` check. Never nest these: a thread holding one
    slot while waiting for another can starve the pool.
    """
    if not _db_slots.acquire(timeout=DB_ACQUIRE_TIMEOUT_SECONDS):
        raise DatabaseBusy("Timed out waiting for a database connection slot.")
    try:
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
    finally:
        _db_slots.release()


def error_response(message, status=500):
    """Return a consistent JSON error envelope.

    Handlers used to return the raw str(e), which exposed driver errors, server names
    and schema details to the caller. The detail belongs in Application Insights, not
    in the response body.
    """
    return jsonify({'error': message}), status


def database_unavailable_response(error=None):
    if isinstance(error, DatabaseBusy):
        return error_response("The broker is busy. Please retry shortly.", 503)
    return error_response("Database connection failed.", 500)


def is_procedure_error(row) -> bool:
    """The TRY/CATCH blocks in several procedures return the SQL error as a result row."""
    return isinstance(row, dict) and 'ErrorNumber' in row


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

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading %s.", label)
        return database_unavailable_response(e)
    except Exception:
        logger.exception("Failed to read %s.", label)
        return error_response(f"Unable to retrieve the {label}.", 500)

def get_remote_host_fqdn(hostname: str) -> str:
    linux_host_admin_login_name = LINUX_HOST_ADMIN_LOGIN_NAME or 'avdadmin'
    return f"{linux_host_admin_login_name}@{hostname}.{DOMAIN_NAME}"

def run_remote_command(hostname: str, command: str, stdin_input: str = None, timeout: int = 120):
    pem_file_path = get_ssh_key_path()
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

def create_or_update_remote_user(hostname: str, username: str, password: str, lease_id: str) -> bool:
    """Provision the user on the host in a single SSH session.

    create-user.sh --password-stdin creates the account, mounts the home, writes the lease,
    adds the remote access groups and sets the password read from stdin. A host still
    running the previous script rejects the extra argument with its usage text before
    changing anything, and is provisioned the old way instead.
    """
    normalized_lease_id = normalize_lease_id(lease_id)
    if not normalized_lease_id:
        logger.error("Cannot provision remote user %s on %s without a valid LeaseId.", username, hostname)
        return False

    try:
        uid = get_or_create_uid(username)
        if not isinstance(uid, int):
            logger.error("Cannot provision remote user %s on %s without a uid.", username, hostname)
            return False

        create_user_command = "sudo {script} --password-stdin {nfs_share} {uid} {username} {lease_id}".format(
            script=REMOTE_CREATE_USER_SCRIPT,
            nfs_share=shlex.quote(NFS_SHARE or ''),
            uid=shlex.quote(str(uid)),
            username=shlex.quote(username),
            lease_id=shlex.quote(normalized_lease_id)
        )

        # Sent over stdin so the credential never appears in the remote process list or auth logs.
        result, host_fqdn = run_remote_command(hostname, create_user_command, stdin_input=f"{password}\n")
        if result.returncode == 0 and CREATE_USER_RESULT_MARKER in (result.stdout or ''):
            return True

        output = f"{result.stdout or ''}\n{result.stderr or ''}"
        if result.returncode != 0 and 'Usage:' in output:
            logger.warning(
                "VM '%s' runs a create-user.sh that predates single-call provisioning. "
                "Update the host scripts with deploy/Migrate-LinuxHostReleaseAgent.ps1.",
                host_fqdn
            )
            return _legacy_create_or_update_remote_user(hostname, username, password, normalized_lease_id, uid)

        logger.error(
            "Failed to provision user '%s' on VM '%s' (exit %s). Error: %s",
            username, host_fqdn, result.returncode, (result.stderr or '').strip()
        )
        return False
    except Exception as e:
        logger.error("Error creating or updating user '%s' on VM '%s': %s", username, hostname, e)
        return False

REMOTE_ACCESS_GROUPS = ("tsusers", "appusers")

def _legacy_create_or_update_remote_user(hostname: str, username: str, password: str, lease_id: str, uid: int) -> bool:
    """The multi-call provisioning sequence, for hosts whose scripts have not been migrated."""
    create_user_command = "sudo {script} {nfs_share} {uid} {username} {lease_id}".format(
        script=REMOTE_CREATE_USER_SCRIPT,
        nfs_share=shlex.quote(NFS_SHARE or ''),
        uid=shlex.quote(str(uid)),
        username=shlex.quote(username),
        lease_id=shlex.quote(lease_id)
    )

    result, host_fqdn = run_remote_command(hostname, create_user_command)
    if result.returncode != 0:
        logger.error("Failed to create or update user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
        return False

    result, host_fqdn = run_remote_command(hostname, 'sudo chpasswd', stdin_input=f"{username}:{password}\n")
    if result.returncode != 0:
        logger.error("Failed to set password for user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
        return False

    for group in REMOTE_ACCESS_GROUPS:
        if not remote_group_exists(hostname, group) and not create_remote_group(hostname, group):
            logger.error("Failed to create group '%s' on VM '%s'.", group, hostname)
            return False
        if not is_user_in_remote_group(hostname, username, group):
            add_user_to_remote_group(hostname, username, group)

    return True

def release_vm_assignment(vmid, lease_id):
    """Return a VM whose checkout failed part-way, claiming the cleanup of its user.

    ReturnVm leaves the VM CleanupPending, so it cannot be handed to anyone else until the
    user has actually been removed from the host. Returns the ReturnVm row, which names the
    user and lease to clean up, or None.
    """
    normalized_lease_id = normalize_lease_id(lease_id)

    if not vmid or not normalized_lease_id:
        return None

    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC ReturnVm @VMID = %s, @ExpectedLeaseId = %s",
                    (vmid, normalized_lease_id)
                )
                row = cursor.fetchone()

            conn.commit()

        if not row or is_procedure_error(row):
            logger.error("Could not return VMID %s after a failed checkout; the lease no longer matches.", vmid)
            return None

        logger.info("Returned VMID %s after a failed checkout.", vmid)
        return row
    except DatabaseUnavailable:
        logger.error("Database connection failed while returning VMID %s after a failed checkout.", vmid)
        return None
    except Exception:
        logger.exception("Error returning VMID %s after a failed checkout.", vmid)
        return None

def generate_secure_password(length=25) -> str:
    characters = string.ascii_letters + string.digits + string.punctuation
    password = ''.join(secrets.choice(characters) for _ in range(length))
    return password

def is_member_of_group(service_principal_id, group_ids):
    access_token = get_access_token(TENANT_ID, CLIENT_ID, MICROSOFT_PROVIDER_AUTHENTICATION_SECRET)
    if not access_token:
        logger.error("Cannot acquire access token for Graph API.")
        raise GroupCheckUnavailable("Could not acquire a Graph API token.")

    headers = {
        'Authorization': f'Bearer {access_token}',
        'Content-Type': 'application/json'
    }

    url = f"{GRAPH_ENDPOINT}/v1.0/servicePrincipals/{service_principal_id}/checkMemberGroups"

    body = {
        "groupIds": group_ids
    }

    response = requests.post(url, headers=headers, json=body, timeout=10)

    if response.status_code == 200:
        result = response.json()
        if result.get('value'):
            return True
        else:
            return False
    else:
        # Raise rather than return False: a throttled or failing Graph call is not
        # evidence that the principal lacks membership, and returning False here
        # would be memoized as a denial for the whole cache window.
        logger.error("Graph API error: %s - %s", response.status_code, response.text)
        raise GroupCheckUnavailable(f"Graph API returned {response.status_code}.")

def _lease_command(action: str, username: str, lease_id: str = None) -> str:
    if lease_id:
        return "sudo {script} {action} {username} {lease_id}".format(
            script=REMOTE_MANAGE_LEASE_SCRIPT,
            action=action,
            username=shlex.quote(username),
            lease_id=shlex.quote(lease_id)
        )
    return "sudo {script} {action} {username}".format(
        script=REMOTE_MANAGE_LEASE_SCRIPT,
        action=action,
        username=shlex.quote(username)
    )

def _user_still_signed_in(stdout: str) -> bool:
    return LEASE_ACTION_IN_USE in stdout or LEASE_ACTION_CLEARED_IN_USE in stdout

def cleanup_remote_user(hostname: str, username: str, lease_id: str = None, force: bool = False, timeout: int = 120) -> str:
    """Remove a returned user's account from a host.

    Returns one of the CLEANUP_* outcomes. Without force, a lease that no longer matches is
    left alone (CLEANUP_SKIPPED), because it may belong to a newer assignment. With force,
    which is only used for a VM the broker holds in CleanupPending and so cannot have
    reassigned, a missing or different lease is cleared anyway.
    """
    normalized_lease_id = normalize_lease_id(lease_id)

    try:
        # manage-lease.sh unmounts the NFS-backed home before it clears the lease, so it runs
        # first on both paths. userdel -r then removes only the empty local mount point, not
        # the profile on the share.
        if normalized_lease_id:
            clear_lease_command = _lease_command('clear', username, normalized_lease_id)
        else:
            clear_lease_command = _lease_command('clear-any', username)

        result, host_fqdn = run_remote_command(hostname, clear_lease_command, timeout=timeout)
        if result.returncode != 0:
            logger.error("Failed to clear the lease for user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return CLEANUP_FAILED

        stdout = result.stdout or ''

        if _user_still_signed_in(stdout):
            logger.warning("User '%s' is still signed in to VM '%s', so the account was left in place.", username, hostname)
            return CLEANUP_IN_USE

        if LEASE_ACTION_CLEARED not in stdout:
            if not force:
                logger.info("Skipped deleting user '%s' on VM '%s' because the lease no longer matches.", username, hostname)
                return CLEANUP_SKIPPED

            if not normalized_lease_id:
                logger.error("Unexpected response while clearing the lease for user '%s' on VM '%s'.", username, host_fqdn)
                return CLEANUP_FAILED

            logger.info(
                "The lease for user '%s' on VM '%s' is missing or different; clearing it because the VM is pending cleanup.",
                username, host_fqdn
            )
            result, host_fqdn = run_remote_command(hostname, _lease_command('clear-any', username), timeout=timeout)
            if result.returncode != 0:
                logger.error("Failed to clear the lease for user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
                return CLEANUP_FAILED

            stdout = result.stdout or ''
            if _user_still_signed_in(stdout):
                logger.warning("User '%s' is still signed in to VM '%s', so the account was left in place.", username, hostname)
                return CLEANUP_IN_USE
            if LEASE_ACTION_CLEARED not in stdout:
                logger.error("Unexpected response while clearing the lease for user '%s' on VM '%s'.", username, host_fqdn)
                return CLEANUP_FAILED

        # A host whose manage-lease.sh predates the unmount can still have the home mounted.
        # Refuse rather than let userdel -r delete the profile on the share. userdel exits 6
        # when the account is already gone and 12 when it removed the account but not the
        # empty mount point; neither leaves an account behind. Anything else, usually 8
        # because processes still run as the user, means the account still exists and the
        # VM must not be handed to anyone else.
        quoted_username = shlex.quote(username)
        home_directory = shlex.quote(f"/home/{username}")
        delete_user_command = (
            f"if mountpoint -q {home_directory}; then echo {HOME_STILL_MOUNTED_MARKER}; exit 1; fi; "
            f"sudo userdel -r {quoted_username} 2>/dev/null; status=$?; "
            f"case $status in 0|6|12) exit 0 ;; esac; "
            f"echo {USERDEL_FAILED_MARKER}$status; exit 1"
        )

        result, host_fqdn = run_remote_command(hostname, delete_user_command, timeout=timeout)

        if result.returncode != 0:
            stdout = result.stdout or ''
            if HOME_STILL_MOUNTED_MARKER in stdout:
                logger.error(
                    "Skipped deleting user '%s' on VM '%s' because its home directory is still mounted. "
                    "Update the host scripts with deploy/Migrate-LinuxHostReleaseAgent.ps1.",
                    username, host_fqdn
                )
            elif USERDEL_FAILED_MARKER in stdout:
                exit_code = stdout.split(USERDEL_FAILED_MARKER, 1)[1].strip().splitlines()[0:1] or ['?']
                logger.error(
                    "User '%s' could not be removed from VM '%s' (userdel exit %s), so the account is still there.",
                    username, host_fqdn, exit_code[0]
                )
            else:
                logger.error("Failed to delete user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return CLEANUP_FAILED

        return CLEANUP_COMPLETED
    except Exception as e:
        logger.error("Error deleting user '%s' on VM '%s': %s", username, hostname, e)
        return CLEANUP_FAILED

def delete_remote_user(hostname: str, username: str, lease_id: str = None) -> bool:
    """Lease-safe removal of a user; True when the account is gone or belongs to someone else."""
    return cleanup_remote_user(hostname, username, lease_id) in (CLEANUP_COMPLETED, CLEANUP_SKIPPED)

def complete_vm_cleanup(vmid, lease_id, username):
    """Clear CleanupPending once the user is gone, so the VM can be checked out again.

    Returns the updated row, or None when nothing matched. A draining host moves to
    Maintenance here instead of becoming available, and that is recorded in the audit log.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC CompleteVmCleanup @VMID = %s, @LeaseId = %s, @Username = %s",
                    (vmid, normalize_lease_id(lease_id), username)
                )
                row = cursor.fetchone()

            conn.commit()
    except DatabaseUnavailable:
        logger.error("Database connection failed while completing the cleanup of VMID %s.", vmid)
        return None
    except Exception:
        logger.exception("Error completing the cleanup of VMID %s.", vmid)
        return None

    if row and row.get('DrainCompleted'):
        audit('vm.drain_completed', 'vm', row.get('Hostname') or vmid, AUDIT_SUCCESS,
              {'vmid': vmid, 'vmStatus': row.get('VmStatus')})

    return row or None

def clean_up_returned_user(vmid, hostname, username, lease_id, timeout: int = 120) -> str:
    """Remove a returned user from its host and then mark the VM clean.

    Anything other than CLEANUP_COMPLETED leaves the VM CleanupPending, and the scheduled
    sweep retries it.
    """
    if not hostname or not username:
        return CLEANUP_NOT_REQUIRED

    outcome = cleanup_remote_user(hostname, username, lease_id, force=True, timeout=timeout)
    if outcome != CLEANUP_COMPLETED:
        return outcome

    if not complete_vm_cleanup(vmid, lease_id, username):
        logger.warning("Removed user '%s' from VM '%s', but VMID %s is still marked for cleanup; the sweep will retry.", username, hostname, vmid)
        return CLEANUP_FAILED

    return CLEANUP_COMPLETED

_jwks_lock = threading.Lock()
_jwks_state = {'keys': None, 'fetched_at': 0.0, 'forced_at': 0.0}
_jwks_forced_refresh_interval_seconds = 60


class JwksUnavailable(Exception):
    """The tenant's token signing keys could not be retrieved and nothing is cached."""


def _download_jwks():
    response = requests.get(f"{AUTHORITY_HOST}/{TENANT_ID}/discovery/v2.0/keys", timeout=10)
    if response.status_code != 200:
        raise JwksUnavailable(f"The JWKS endpoint returned {response.status_code}.")
    keys = response.json().get("keys")
    if not isinstance(keys, list):
        raise JwksUnavailable("The JWKS response did not contain a key list.")
    return keys


def _refresh_jwks(now):
    try:
        keys = _download_jwks()
    except Exception:
        if _jwks_state['keys'] is None:
            raise JwksUnavailable("No token signing keys are available.")
        # Entra rotates keys slowly and with overlap, so the last known set stays usable.
        # Try again in a minute rather than adding a download timeout to every request.
        logger.warning("Could not refresh the token signing keys; using the cached set.", exc_info=True)
        _jwks_state['fetched_at'] = now - JWKS_CACHE_SECONDS + _jwks_forced_refresh_interval_seconds
        return _jwks_state['keys']

    _jwks_state['keys'] = keys
    _jwks_state['fetched_at'] = now
    return keys


def get_signing_key(kid):
    """Return the signing key for kid, downloading the tenant's key set once per cache window.

    Every request used to download the key set. An unknown kid forces one early refresh,
    rate limited, so a key rotation is picked up without letting a stream of forged tokens
    hammer the discovery endpoint.
    """
    with _jwks_lock:
        now = time.monotonic()
        keys = _jwks_state['keys']
        if keys is None or now - _jwks_state['fetched_at'] >= JWKS_CACHE_SECONDS:
            keys = _refresh_jwks(now)

        key = next((candidate for candidate in keys if candidate.get("kid") == kid), None)
        forced_at = _jwks_state['forced_at']
        if key is None and (not forced_at or now - forced_at >= _jwks_forced_refresh_interval_seconds):
            _jwks_state['forced_at'] = now
            keys = _refresh_jwks(now)
            key = next((candidate for candidate in keys if candidate.get("kid") == kid), None)

        return key


_legacy_warning_lock = threading.Lock()
_legacy_warning_state = {'logged_at': 0.0}


def effective_roles(payload):
    """App roles granted by the token, plus FullAccess for the legacy scope when enabled.

    Returns (roles, legacy) where legacy is True only when FullAccess came from the legacy
    ALLOW_LEGACY_SCOPE_ACCESS toggle rather than from a role assignment.
    """
    raw_roles = payload.get('roles') or []
    if isinstance(raw_roles, str):
        raw_roles = [raw_roles]
    roles = {str(role) for role in raw_roles}

    legacy = False
    if ALLOW_LEGACY_SCOPE_ACCESS and ROLE_ADMIN not in roles:
        scopes = str(payload.get('scp') or '').split()
        if LEGACY_DELEGATED_SCOPE in scopes:
            roles.add(ROLE_ADMIN)
            legacy = True

    return roles, legacy


def _warn_legacy_scope_access():
    with _legacy_warning_lock:
        now = time.monotonic()
        if _legacy_warning_state['logged_at'] and now - _legacy_warning_state['logged_at'] < 300:
            return
        _legacy_warning_state['logged_at'] = now
    logger.warning(
        "A caller was granted FullAccess through the access_as_user scope because "
        "ALLOW_LEGACY_SCOPE_ACCESS is enabled. Assign the Reader, Operator or FullAccess "
        "app roles and turn the setting off."
    )


@cache.memoize(timeout=300)
def is_member_of_group_cached(user_oid, group_ids):
    # memoize needs hashable arguments, so the caller passes a tuple.
    return is_member_of_group(user_oid, list(group_ids))


def token_required(required_permissions=None, required_group_ids=None, allow_any_authenticated=False):
    """Validate the bearer token and authorize the caller.

    A caller is authorized when the token carries one of required_permissions as an app
    role, or when it belongs to one of required_group_ids. The group check calls Microsoft
    Graph, so it only runs when no role already authorizes the call; the outcome is the
    same either way. Delegated scopes are deliberately not permissions: every portal user
    holds access_as_user, so it cannot distinguish a reader from an administrator.
    """
    allowed_roles = tuple(required_permissions or ())
    group_ids = tuple(group_id for group_id in (required_group_ids or ()) if group_id)

    def decorator(f):
        audit_action = getattr(f, '_audit_action', None)
        audit_target_type = getattr(f, '_audit_target_type', None)

        @wraps(f)
        def decorated(*args, **kwargs):
            token = None

            if 'Authorization' in request.headers:
                auth_header = request.headers['Authorization']
                parts = auth_header.split()
                if len(parts) == 2 and parts[0] == 'Bearer':
                    token = parts[1]
                else:
                    logger.error("Authorization header is malformed. Expected 'Bearer <token>'.")

            if not token:
                logger.error("Token is missing in the request.")
                return jsonify({'message': 'Token is missing!'}), 401

            try:
                unverified_header = jwt.get_unverified_header(token)

                try:
                    jwk = get_signing_key(unverified_header.get("kid"))
                except JwksUnavailable:
                    logger.exception("Could not retrieve the token signing keys.")
                    return jsonify({'message': 'Failed to retrieve JWKS.'}), 500

                if not jwk:
                    return jsonify({'message': 'Invalid token: RSA key not found.'}), 401

                rsa_key = {
                    "kty": jwk.get("kty"),
                    "kid": jwk.get("kid"),
                    "use": jwk.get("use", "sig"),
                    "n": jwk.get("n"),
                    "e": jwk.get("e")
                }

                valid_audiences = [
                    CLIENT_ID,
                    APP_URI,
                ]

                expected_issuers = [
                    f"{AUTHORITY_HOST}/{TENANT_ID}/v2.0",
                    f"{AUTHORITY_HOST}/{TENANT_ID}/",
                    f"{STS_ISSUER_HOST}/{TENANT_ID}/"
                ]

                payload = jwt.decode(
                    token,
                    key=jwt.algorithms.RSAAlgorithm.from_jwk(rsa_key),
                    algorithms=['RS256'],
                    audience=valid_audiences,
                    issuer=expected_issuers
                )

                user_oid = payload.get('oid')
                if not user_oid:
                    return jsonify({'message': 'Token does not contain user ID (oid).'}), 403

                roles, legacy = effective_roles(payload)
                authorized = allow_any_authenticated or bool(roles.intersection(allowed_roles))

                if not authorized and group_ids:
                    # Use the memoized wrapper: this runs on every authenticated
                    # request from the AVD and Linux hosts, and the uncached path was
                    # calling Microsoft Graph each time.
                    try:
                        authorized = is_member_of_group_cached(user_oid, group_ids)
                    except GroupCheckUnavailable:
                        # Not cached, and reported as a dependency failure rather than
                        # a denial, so a Graph blip does not look like a permissions
                        # problem to the AVD and Linux host agents.
                        logger.exception("Could not verify group membership for %s.", user_oid)
                        return jsonify({'error': 'Unable to verify group membership. Please retry.'}), 503

                if not authorized:
                    logger.error("Access denied: insufficient role permissions or group membership.")
                    if (request.method not in ('GET', 'HEAD', 'OPTIONS')
                            and request.endpoint not in READ_ONLY_POST_ENDPOINTS
                            and denial_audit_allowed(user_oid)):
                        audit(
                            audit_action or f"route.{request.endpoint}",
                            audit_target_type,
                            next((value for value in kwargs.values() if value is not None), None),
                            AUDIT_DENIED,
                            {
                                'method': request.method,
                                'path': request.path,
                                'requiredRoles': sorted(allowed_roles),
                                'callerRoles': sorted(roles),
                            },
                            claims=payload,
                        )
                    return jsonify({'message': 'Access denied: insufficient role permissions or group membership.'}), 403

                if legacy:
                    _warn_legacy_scope_access()

            except jwt.ExpiredSignatureError:
                logger.error("Token has expired.")
                return jsonify({'message': 'Token has expired.'}), 401
            except jwt.InvalidAudienceError as e:
                logger.error("Invalid audience: %s", e)
                return jsonify({'message': 'Invalid audience.'}), 401
            except jwt.InvalidIssuerError as e:
                logger.error("Invalid issuer: %s", e)
                return jsonify({'message': 'Invalid issuer.'}), 401
            except Exception as e:
                logger.error("Token validation error: %s", e)
                return jsonify({'message': 'Token is invalid.'}), 401

            g.token_claims = payload
            g.effective_roles = roles
            g.legacy_scope_access = legacy
            return f(*args, **kwargs)

        # Recorded so the tests can check every route's authorization against the contract.
        decorated._allowed_roles = allowed_roles
        decorated._allowed_groups = group_ids
        decorated._allow_any_authenticated = allow_any_authenticated
        return decorated
    return decorator


def is_delegated_caller():
    """True for a user signed in through the portal; False for a managed identity."""
    claims = getattr(g, 'token_claims', None) or {}
    return bool(claims.get('scp'))


def caller_is_admin():
    return ROLE_ADMIN in (getattr(g, 'effective_roles', None) or set())

# ===============================
# Audit log
#
# Who changed what. The @audited decorator records every call a portal user or an
# administrator principal makes to a mutating route, token_required records authorization
# denials on those routes, and handlers record the state changes the broker makes on its own:
# scaling power actions, power states corrected from Azure, expired releases, and completed
# cleanups and drains. Routine agent calls are not audited. The AVD hosts' checkouts, the
# Linux hosts' releases, acknowledgements and heartbeats, and the scheduled task's probes are
# high volume, and VirtualMachinesHistory already records what they change.

AUDIT_ACTOR_USER = 'user'
AUDIT_ACTOR_SERVICE = 'service'
AUDIT_ACTOR_SYSTEM = 'system'
AUDIT_SUCCESS = 'success'
AUDIT_FAILURE = 'failure'
AUDIT_DENIED = 'denied'
AUDIT_OUTCOMES = (AUDIT_SUCCESS, AUDIT_FAILURE, AUDIT_DENIED)

# POST routes that only read. They carry no audit action and their denials are not audited.
READ_ONLY_POST_ENDPOINTS = frozenset({'get_vm_history', 'get_scaling_activity_log', 'get_scaling_rules_history'})

_MIRID_RESOURCE_NAME_RE = re.compile(r'/providers/[^/]+/[^/]+/(?P<name>[^/]+)/?$', re.IGNORECASE)
_MIRID_VM_NAME_RE = re.compile(r'/providers/Microsoft\.Compute/virtualMachines/(?P<name>[^/]+)/?$', re.IGNORECASE)

audit_logger = logging.getLogger('linuxbroker.api.audit')


def _request_claims():
    if not has_app_context():
        return {}
    return getattr(g, 'token_claims', None) or {}


def audit_actor(claims=None):
    """(object id, display name, actor type) for the caller, from its validated token.

    A portal user is named by their sign-in name. A managed identity has no name claim, so
    it is named by the resource it belongs to (the VM or function app in xms_mirid), which is
    what an operator recognizes, and otherwise by its application id.
    """
    claims = _request_claims() if claims is None else (claims or {})
    if not claims:
        return None, None, AUDIT_ACTOR_SYSTEM

    oid = str(claims.get('oid') or '').strip() or None
    if claims.get('scp'):
        name = (claims.get('preferred_username') or claims.get('upn') or claims.get('unique_name')
                or claims.get('email') or claims.get('name'))
        return oid, (str(name) if name else None), AUDIT_ACTOR_USER

    match = _MIRID_RESOURCE_NAME_RE.search(str(claims.get('xms_mirid') or ''))
    name = match.group('name') if match else (claims.get('app_displayname') or claims.get('appid') or claims.get('azp'))
    return oid, (str(name) if name else None), AUDIT_ACTOR_SERVICE


def audit_correlation_id():
    """The OpenTelemetry trace id when the request is traced, otherwise one id per request."""
    if otel_trace is not None:
        try:
            context = otel_trace.get_current_span().get_span_context()
            if context is not None and context.is_valid:
                return format(context.trace_id, '032x')
        except Exception:
            pass

    if not has_app_context():
        return uuid.uuid4().hex

    correlation_id = getattr(g, 'audit_correlation_id', None)
    if not correlation_id:
        correlation_id = uuid.uuid4().hex
        g.audit_correlation_id = correlation_id
    return correlation_id


def audit_detail_json(detail):
    """Serialize curated detail, bounded so one entry cannot grow without limit."""
    if not detail:
        return None
    try:
        text = json.dumps(serialize_for_json(detail), default=str, sort_keys=True)
    except (TypeError, ValueError):
        return None
    if len(text) <= AUDIT_DETAIL_MAX_CHARS:
        return text

    # Escaping can lengthen the excerpt, so shrink it until the envelope fits.
    excerpt = text[:AUDIT_DETAIL_MAX_CHARS - 64]
    while True:
        bounded = json.dumps({'truncated': True, 'excerpt': excerpt})
        if len(bounded) <= AUDIT_DETAIL_MAX_CHARS or not excerpt:
            return bounded
        excerpt = excerpt[:len(excerpt) // 2]


def write_audit_entry(entry):
    """Store one audit entry. Never raises: a failure to audit must not fail the operation."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC WriteAuditEntry @ActorOid = %s, @ActorName = %s, @ActorType = %s, @Action = %s, "
                    "@TargetType = %s, @TargetId = %s, @Outcome = %s, @DetailJson = %s, @CorrelationId = %s",
                    (entry['actorOid'], entry['actorName'], entry['actorType'], entry['action'],
                     entry['targetType'], entry['targetId'], entry['outcome'], entry['detailJson'],
                     entry['correlationId'])
                )
                cursor.fetchone()
            conn.commit()
        return True
    except Exception:
        logger.exception("Could not write the audit entry for %s.", entry.get('action'))
        return False


def audit(action, target_type=None, target_id=None, outcome=AUDIT_SUCCESS, detail=None, claims=None):
    """Record an audited event in SQL, and as a structured log record for Application Insights."""
    try:
        oid, name, actor_type = audit_actor(claims)
        entry = {
            'action': action,
            'targetType': target_type,
            'targetId': None if target_id in (None, '') else str(target_id),
            'outcome': outcome,
            'actorOid': oid,
            'actorName': name,
            'actorType': actor_type,
            'detailJson': audit_detail_json(detail),
            'correlationId': audit_correlation_id(),
        }

        # Telemetry attributes cannot be None, so absent values are left out.
        attributes = {
            f"audit_{key}": value for key, value in (
                ('action', entry['action']), ('outcome', entry['outcome']),
                ('target_type', entry['targetType']), ('target_id', entry['targetId']),
                ('actor_oid', entry['actorOid']), ('actor_name', entry['actorName']),
                ('actor_type', entry['actorType']), ('detail', entry['detailJson']),
                ('correlation_id', entry['correlationId']),
            ) if value is not None
        }
        audit_logger.info(
            "Audit: %s %s on %s %s by %s.",
            action, outcome, target_type or '-', entry['targetId'] or '-', name or oid or actor_type,
            extra=attributes,
        )

        write_audit_entry(entry)
    except Exception:
        logger.exception("Could not audit %s.", action)


def caller_is_audited():
    """Portal users and administrator principals are audited; agents' routine calls are not."""
    if not has_app_context():
        return False
    if is_delegated_caller():
        return True
    roles = getattr(g, 'effective_roles', None) or set()
    return bool(roles.intersection(READ_ROLES))


# Any signed-in tenant principal can be denied, so denials are capped per caller and worker
# process: past the cap they are still logged, but no longer written to SQL, so a loop of
# refused calls cannot fill the audit table.
DENIAL_AUDITS_PER_MINUTE = 30


def denial_audit_allowed(oid):
    key = f"audit-denials:{oid or 'unknown'}"
    count = cache.get(key) or 0
    if count >= DENIAL_AUDITS_PER_MINUTE:
        logger.warning("Not auditing a further denial for %s this minute.", oid)
        return False
    # Approximate across threads, which is enough for a flood guard.
    cache.set(key, count + 1, timeout=60)
    return True


def _response_body_and_status(rv):
    if isinstance(rv, tuple):
        body = rv[0]
        status = rv[1] if len(rv) > 1 and isinstance(rv[1], int) else getattr(body, 'status_code', 200)
        return body, int(status)
    return rv, int(getattr(rv, 'status_code', 200) or 200)


def _response_error_text(body):
    """The curated message from an error envelope. Never the body of a success."""
    try:
        payload = body.get_json(silent=True) if hasattr(body, 'get_json') else body
    except Exception:
        return None
    if isinstance(payload, dict):
        text = payload.get('error') or payload.get('message')
        if text:
            return str(text)[:300]
    return None


def audited(action, target_type=None, target_param=None):
    """Record the outcome of a mutating route in the audit log.

    Sits under @token_required, so it only runs for authorized callers; token_required audits
    denials itself, using the action recorded here. A handler adds context through
    g.audit_target_id (the hostname, where it is known) and g.audit_detail. The detail is
    curated and never includes a response body, so no password or lease id can reach the log.
    """
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            g.audit_target_id = None
            g.audit_detail = {}
            rv = f(*args, **kwargs)

            try:
                if caller_is_audited():
                    body, status = _response_body_and_status(rv)
                    if status == 403:
                        outcome = AUDIT_DENIED
                    elif status < 400:
                        outcome = AUDIT_SUCCESS
                    else:
                        outcome = AUDIT_FAILURE

                    detail = dict(getattr(g, 'audit_detail', None) or {})
                    detail['status'] = status
                    param_value = kwargs.get(target_param) if target_param else None
                    if param_value is not None:
                        detail.setdefault(target_param, param_value)
                    if status >= 400:
                        error_text = _response_error_text(body)
                        if error_text:
                            detail['error'] = error_text

                    target_id = getattr(g, 'audit_target_id', None) or param_value
                    audit(action, target_type, target_id, outcome, detail)
            except Exception:
                logger.exception("Could not audit %s.", action)

            return rv

        wrapper._audit_action = action
        wrapper._audit_target_type = target_type
        return wrapper
    return decorator

def remote_group_exists(hostname: str, group_name: str) -> bool:
    try:
        result, host_fqdn = run_remote_command(hostname, f"getent group {shlex.quote(group_name)}")
        if result.returncode == 0:
            return True

        logger.info("Group '%s' does not exist on VM '%s'. Error: %s", group_name, host_fqdn, result.stderr)
        return False
    except Exception as e:
        logger.error("Error checking group '%s' on VM '%s': %s", group_name, hostname, e)
        return False

def create_remote_group(hostname: str, group_name: str) -> bool:
    try:
        result, host_fqdn = run_remote_command(hostname, f"sudo groupadd {shlex.quote(group_name)}")
        if result.returncode == 0:
            return True

        logger.error("Failed to create group '%s' on VM '%s'. Error: %s", group_name, host_fqdn, result.stderr)
        return False
    except Exception as e:
        logger.error("Error creating group '%s' on VM '%s': %s", group_name, hostname, e)
        return False

def is_user_in_remote_group(hostname: str, username: str, group_name: str) -> bool:
    try:
        result, host_fqdn = run_remote_command(hostname, f"id -nG {shlex.quote(username)}")
        if result.returncode != 0:
            logger.error("Error checking user '%s' on VM '%s': %s", username, host_fqdn, result.stderr)
            return False

        return group_name in result.stdout.strip().split()
    except Exception as e:
        logger.error("Error checking user '%s' in group '%s' on VM '%s': %s", username, group_name, hostname, e)
        return False

def add_user_to_remote_group(hostname: str, username: str, group_name: str) -> None:
    try:
        command = f"sudo usermod -aG {shlex.quote(group_name)} {shlex.quote(username)}"
        result, host_fqdn = run_remote_command(hostname, command)
        if result.returncode != 0:
            logger.error("Failed to add user '%s' to group '%s' on VM '%s': %s", username, group_name, host_fqdn, result.stderr)
    except Exception as e:
        logger.error("Error adding user '%s' to group '%s' on VM '%s': %s", username, group_name, hostname, e)

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

def host_settings_document(settings: dict) -> dict:
    """The settings document as sent to a Linux host.

    Settings newer than the first host agent release are left out while they hold their
    default, because an un-migrated apply-host-settings.sh rejects keys it does not know.
    """
    document = dict(settings)
    for field in HOST_DOCUMENT_OPTIONAL_BOOLEANS:
        if not document.get(field):
            document.pop(field, None)
    return document

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

def apply_host_settings_to_host(hostname: str, settings: dict, timeout: int = 120):
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
            stdin_input=json.dumps(host_settings_document(settings)),
            timeout=timeout
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
@token_required(allow_any_authenticated=True)
def get_me():
    """The caller's app roles and what they allow, so the portal can adapt its interface.

    The portal only uses this to decide what to show; every endpoint still enforces its
    own roles.
    """
    claims = getattr(g, 'token_claims', None) or {}
    raw_roles = claims.get('roles') or []
    if isinstance(raw_roles, str):
        raw_roles = [raw_roles]
    roles = getattr(g, 'effective_roles', None) or set()

    return jsonify({
        'roles': sorted({str(role) for role in raw_roles}),
        'permissions': {
            'read': bool(roles.intersection(READ_ROLES)),
            'operate': bool(roles.intersection(OPERATE_ROLES)),
            'admin': bool(roles.intersection(ADMIN_ROLES)),
        },
        'legacyScopeAccess': bool(getattr(g, 'legacy_scope_access', False)),
    }), 200

# ===============================
# VM Management APIs

@app.route('/api/vms', methods=['GET'])
@token_required(READ_ROLES + [ROLE_SCHEDULED_TASK])
def get_all_vms():
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                rows = cursor.fetchall()

        return jsonify(serialize_for_json(rows or [])), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while listing VMs.")
        return database_unavailable_response(e)
    except Exception:
        logger.exception("Failed to list VMs.")
        return error_response("Unable to retrieve virtual machines.", 500)

@app.route('/api/vms/summary', methods=['GET'])
@token_required(READ_ROLES + [ROLE_SCHEDULED_TASK])
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
                  'PoweredOn', 'PoweredOff', 'Unreachable', 'Ready', 'CleanupPending', 'Draining')
        normalized = {field: int(summary.get(field) or 0) for field in fields}

        return jsonify(normalized), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while building the VM summary.")
        return database_unavailable_response(e)
    except Exception:
        logger.exception("Failed to build the VM summary.")
        return error_response("Unable to retrieve the virtual machine summary.", 500)

@app.route('/api/vms/checkout', methods=['POST'])
@token_required([ROLE_AVD_HOST, ROLE_ADMIN], required_group_ids=[AVD_HOST_GROUP_ID])
@audited('vm.checkout', target_type='vm')
def checkout_vm():
    try:
        req_body = request.get_json(silent=True) or {}

        username = req_body.get('username')
        avdhost = req_body.get('avdhost')

        if not isinstance(username, str) or not isinstance(avdhost, str) or not username or not avdhost:
            return error_response("Please provide 'username' and 'avdhost' in the request body.", 400)

        username = re.sub(r'[^a-zA-Z0-9_]', '', username)
        if not username:
            return error_response("The username contains no characters a Linux account can use.", 400)

        g.audit_detail = {'username': username, 'avdhost': avdhost}
        user_password = generate_secure_password()

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.callproc('CheckoutVm', (username, avdhost))
                rows = cursor.fetchall()
                conn.commit()

        if rows and is_procedure_error(rows[0]):
            logger.error("CheckoutVm failed with SQL error %s.", rows[0].get('ErrorNumber'))
            return error_response("Unable to check out a virtual machine.", 500)

        if not rows or 'Message' in rows[0]:
            return error_response("No available VM found. Please try again.", 409)

        checked_out_vm = rows[0]
        vmid = checked_out_vm.get("VMID")
        vm_hostname = checked_out_vm.get('Hostname')
        lease_id = normalize_lease_id(checked_out_vm.get('LeaseId'))
        g.audit_target_id = vm_hostname

        if not vm_hostname or not lease_id:
            return error_response("No hostname or LeaseId found for the checked-out VM.", 500)

        # A requested profile reset is applied on a new assignment only, before create-user.sh
        # mounts the home. It never stops the user signing in.
        if checked_out_vm.get('ProfileResetRequested') and checked_out_vm.get('CheckoutType') == 'Assigned':
            apply_pending_profile_reset(vmid, vm_hostname, username)

        if not create_or_update_remote_user(vm_hostname, username, user_password, lease_id):
            # create-user.sh may already have written the lease and mounted the home. The VM
            # goes back CleanupPending, so it cannot be handed to anyone else until the user
            # has actually been removed; the scheduled sweep retries if this attempt fails.
            returned = release_vm_assignment(vmid, lease_id)
            if returned:
                clean_up_returned_user(
                    vmid,
                    returned.get('Hostname') or vm_hostname,
                    returned.get('ReturnedUsername') or username,
                    returned.get('ReturnedLeaseId') or lease_id,
                    timeout=30
                )
            return error_response(f"Failed to create or update user '{username}' on VM '{vm_hostname}'.", 500)

        response_data = {
            "VMID": vmid,
            "Hostname": vm_hostname,
            "IPAddress": checked_out_vm.get("IPAddress"),
            "LeaseId": lease_id,
            "password": user_password
        }

        return jsonify(serialize_for_json(response_data)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while checking out a VM.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to check out a VM.")
        return error_response("Unable to check out a virtual machine.", 500)

def _validate_choice(value, field, choices):
    if value is not None and value not in choices:
        return f"{field} must be one of: {', '.join(choices)}."
    return None

@app.route('/api/vms/<int:vmid>/update-attributes', methods=['POST'])
@token_required(ADMIN_ROLES + [ROLE_SCHEDULED_TASK])
@audited('vm.update_attributes', target_type='vm', target_param='vmid')
def update_vm_attributes(vmid):
    """Admin repair of the broker's record for a VM. It never starts or stops anything.

    ScheduledTask keeps access because task builds older than /network-status report
    reachability through this endpoint.
    """
    try:
        req_body = request.get_json(silent=True) or {}

        powerstate = req_body.get('powerstate') or None
        networkstatus = req_body.get('networkstatus') or None
        vmstatus = req_body.get('vmstatus') or None
        g.audit_detail = {'powerstate': powerstate, 'networkstatus': networkstatus, 'vmstatus': vmstatus}

        if not any([powerstate, networkstatus, vmstatus]):
            return error_response("Please provide at least one attribute to update.", 400)

        for value, field, choices in (
            (powerstate, 'powerstate', VALID_POWER_STATES),
            (networkstatus, 'networkstatus', VALID_NETWORK_STATUSES),
            (vmstatus, 'vmstatus', VALID_VM_STATUSES),
        ):
            problem = _validate_choice(value, field, choices)
            if problem:
                return error_response(problem, 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC UpdateVmAttributes @VMID = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s",
                    (vmid, powerstate, networkstatus, vmstatus)
                )
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response("VM not found or no attributes updated. Please try again.", 404)

        g.audit_target_id = row.get('Hostname')
        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while updating VM %s attributes.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to update VM %s attributes.", vmid)
        return error_response("Unable to update virtual machine attributes.", 500)

@app.route('/api/vms/<int:vmid>/network-status', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
@audited('vm.network_status', target_type='vm', target_param='vmid')
def set_vm_network_status(vmid):
    """Record a reachability probe result. Writes only when the status actually changed."""
    try:
        req_body = request.get_json(silent=True) or {}
        networkstatus = req_body.get('networkstatus')

        if networkstatus not in VALID_NETWORK_STATUSES:
            return error_response("networkstatus must be one of: Reachable, Unreachable.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC SetVmNetworkStatus @VMID = %s, @NetworkStatus = %s",
                    (vmid, networkstatus)
                )
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} was not found.", 404)

        g.audit_target_id = row.get('Hostname')
        g.audit_detail = {'networkstatus': networkstatus, 'changed': bool(row.get('Changed'))}
        body = serialize_for_json(row)
        body['Changed'] = bool(row.get('Changed'))
        return jsonify(body), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while recording the network status of VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to record the network status of VM %s.", vmid)
        return error_response("Unable to record the network status.", 500)

@app.route('/api/vms/<int:vmid>/maintenance', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.maintenance', target_type='vm', target_param='vmid')
def set_vm_maintenance(vmid):
    """Take an unassigned host out of rotation, or put it back."""
    try:
        req_body = request.get_json(silent=True) or {}
        enabled = req_body.get('enabled')

        if not isinstance(enabled, bool):
            return error_response("Provide 'enabled' as true or false.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC SetVmMaintenance @VMID = %s, @Enabled = %s", (vmid, enabled))
                row = cursor.fetchone()
            conn.commit()

        result = (row or {}).get('Result')
        hostname = (row or {}).get('Hostname') or f"VMID {vmid}"
        g.audit_target_id = (row or {}).get('Hostname')
        g.audit_detail = {'enabled': enabled, 'result': result}

        if result in ('Updated', 'Unchanged'):
            return jsonify(serialize_for_json({
                'VMID': row.get('VMID'),
                'Hostname': row.get('Hostname'),
                'VmStatus': row.get('VmStatus'),
                'Result': result,
            })), 200

        if result == 'Assigned':
            return error_response(f"VM {hostname} is assigned to a user. Return it before changing maintenance.", 409)

        if result == 'InvalidState':
            return error_response(f"VM {hostname} is in a state maintenance cannot change. Repair its status first.", 409)

        return error_response(f"VM with VMID {vmid} was not found.", 404)

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while changing maintenance for VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to change maintenance for VM %s.", vmid)
        return error_response("Unable to change maintenance for the virtual machine.", 500)

@app.route('/api/vms/<int:vmid>/cleanup', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.cleanup_retry', target_type='vm', target_param='vmid')
def retry_vm_cleanup(vmid):
    """Retry removing a returned user from a host now, instead of waiting for the sweep."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC BeginVmCleanupRetry @VMID = %s", (vmid,))
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"VM {vmid} has no pending cleanup.", 409)

        hostname = row.get('Hostname')
        username = row.get('CleanupUsername')
        lease_id = row.get('CleanupLeaseId')
        g.audit_target_id = hostname

        if username:
            outcome = clean_up_returned_user(vmid, hostname, username, lease_id, timeout=60)
        else:
            outcome = CLEANUP_COMPLETED if complete_vm_cleanup(vmid, lease_id, None) else CLEANUP_FAILED

        g.audit_detail = {'username': username, 'cleanupResult': outcome}

        body = {
            'VMID': vmid,
            'Hostname': hostname,
            'CleanupResult': outcome,
            'CleanupPending': outcome != CLEANUP_COMPLETED,
        }

        if outcome == CLEANUP_COMPLETED:
            body['message'] = f"Cleanup of {hostname} completed. The host is available again."
            return jsonify(body), 200

        if outcome == CLEANUP_IN_USE:
            body['error'] = f"{username} is still signed in to {hostname}. Cleanup will be retried automatically."
            return jsonify(body), 409

        body['error'] = f"Could not clean up {hostname}. It will be retried automatically."
        return jsonify(body), 502

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while retrying cleanup of VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to retry cleanup of VM %s.", vmid)
        return error_response("Unable to retry the cleanup.", 500)

@app.route('/api/vms/<int:vmid>/delete', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('vm.delete', target_type='vm', target_param='vmid')
def delete_vm(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteVm @VMID = %s", (vmid,))
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} could not be deleted or was not found.", 404)

        g.audit_target_id = row.get('Hostname')
        g.audit_detail = {'vmStatus': row.get('VmStatus'), 'username': row.get('Username')}
        return jsonify({'message': f"VM with VMID {vmid} has been successfully deleted.", 'VMID': vmid}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while deleting VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to delete VM %s.", vmid)
        return error_response("Unable to delete the virtual machine.", 500)

@app.route('/api/vms/add', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('vm.add', target_type='vm')
def add_new_vm():
    try:
        req_body = request.get_json(silent=True) or {}

        hostname = req_body.get('hostname')
        ipaddress = req_body.get('ipaddress')
        powerstate = req_body.get('powerstate')
        networkstatus = req_body.get('networkstatus')
        vmstatus = req_body.get('vmstatus')
        # Blank strings are stored as NULL: checkout and scaling only use hosts whose
        # Username is NULL, so an empty string would leave the new host unusable.
        username = str(req_body.get('username') or '').strip() or None
        avdhost = str(req_body.get('avdhost') or '').strip() or None
        description = str(req_body.get('description') or '').strip() or None
        g.audit_target_id = str(hostname) if hostname else None
        g.audit_detail = {
            'ipaddress': ipaddress, 'powerstate': powerstate, 'networkstatus': networkstatus,
            'vmstatus': vmstatus, 'username': username,
        }

        if not (hostname and ipaddress and powerstate and networkstatus and vmstatus):
            return error_response("Please provide 'hostname', 'ipaddress', 'powerstate', 'networkstatus', and 'vmstatus' in the request body.", 400)

        for value, field, choices in (
            (powerstate, 'powerstate', VALID_POWER_STATES),
            (networkstatus, 'networkstatus', VALID_NETWORK_STATUSES),
            (vmstatus, 'vmstatus', VALID_VM_STATUSES),
        ):
            problem = _validate_choice(value, field, choices)
            if problem:
                return error_response(problem, 400)

        if username and vmstatus not in ('CheckedOut', 'Released'):
            return error_response("A username can only be recorded for a CheckedOut or Released host.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("""
                    EXEC AddVm @Hostname = %s, @IPAddress = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s,
                                @Username = %s, @AvdHost = %s, @Description = %s
                """, (hostname, ipaddress, powerstate, networkstatus, vmstatus, username, avdhost, description))

                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response("Failed to add new VM. Please try again.", 500)

        return jsonify(serialize_for_json({"NewVMID": row['NewVMID']})), 201

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while adding a VM.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to add a VM.")
        return error_response("Unable to add the virtual machine.", 500)

@app.route('/api/vms/<int:vmid>', methods=['GET'])
@token_required(READ_ROLES)
def get_vm_details(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVmDetails @VMID = %s", (vmid,))
                row = cursor.fetchone()

        if not row:
            return error_response(f"VM with VMID {vmid} was not found.", 404)

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read VM %s.", vmid)
        return error_response("Unable to retrieve the virtual machine.", 500)

@app.route('/api/vms/<int:vmid>/return', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.return', target_type='vm', target_param='vmid')
def return_vm(vmid):
    """End an assignment now. The VM stays CleanupPending until its user is off the host."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC ReturnVm @VMID = %s", (vmid,))
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} was not found or is not currently checked out.", 404)

        if is_procedure_error(row):
            logger.error("ReturnVm failed for VM %s with SQL error %s.", vmid, row.get('ErrorNumber'))
            return error_response("Unable to return the virtual machine.", 500)

        hostname = row.get('Hostname')
        username = row.get('ReturnedUsername')
        g.audit_target_id = hostname
        outcome = clean_up_returned_user(vmid, hostname, username, row.get('ReturnedLeaseId'), timeout=60)
        g.audit_detail = {'username': username, 'cleanupResult': outcome}

        if outcome == CLEANUP_COMPLETED:
            logger.info("Removed user %s from %s during manual return.", username, hostname)
        elif outcome != CLEANUP_NOT_REQUIRED:
            logger.warning("User %s could not be removed from %s during manual return (%s); the sweep will retry.", username, hostname, outcome)

        body = serialize_for_json(row)
        body['CleanupResult'] = outcome
        body['CleanupPending'] = outcome not in (CLEANUP_COMPLETED, CLEANUP_NOT_REQUIRED)
        return jsonify(body), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while returning VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to return VM %s.", vmid)
        return error_response("Unable to return the virtual machine.", 500)

@app.route('/api/vms/<hostname>/release', methods=['POST'])
@token_required(OPERATE_ROLES + [ROLE_LINUX_HOST], required_group_ids=[LINUX_HOST_GROUP_ID])
@audited('vm.release', target_type='vm', target_param='hostname')
def release_vm(hostname):
    try:
        req_body = request.get_json(silent=True) or {}
        lease_id_raw = req_body.get('leaseId') or request.args.get('leaseId')
        username = req_body.get('username') or request.args.get('username')
        lease_id = normalize_lease_id(lease_id_raw)

        if lease_id_raw and not lease_id:
            return jsonify({'error': 'Invalid leaseId format.'}), 400

        if username:
            username = re.sub(r'[^a-zA-Z0-9_]', '', str(username))

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC ReleaseVm @Hostname = %s, @LeaseId = %s, @Username = %s",
                    (hostname, lease_id, username)
                )
                row = cursor.fetchone()

            conn.commit()

        if not row or is_procedure_error(row):
            if row:
                logger.error("ReleaseVm failed for %s with SQL error %s.", hostname, row.get('ErrorNumber'))
            return error_response(f"Failed to release VM with Hostname {hostname}. Please try again.", 500)

        release_status = (row.get('ReleaseStatus') or '').strip()
        g.audit_detail = {'username': username, 'releaseStatus': release_status}

        if release_status == 'NotFound':
            return jsonify({'error': f"No VM found with Hostname {hostname}.", 'ReleaseStatus': release_status}), 404

        if release_status == 'LeaseMismatch':
            return jsonify({
                'error': f"Release request did not match the current assignment for Hostname {hostname}.",
                'ReleaseStatus': release_status
            }), 409

        # NoActiveAssignment means the VM is already released, so the agent should stop retrying.
        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while releasing VM with Hostname %s.", hostname)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to release VM with Hostname %s.", hostname)
        return error_response("Unable to release the virtual machine.", 500)

SWEEP_COMMAND_TIMEOUT_SECONDS = 30

def _sweep_cleanup(row, deadline):
    hostname = row.get('Hostname')
    username = row.get('ReturnedUsername')

    if not hostname or not username:
        return CLEANUP_NOT_REQUIRED

    # An off or unreachable host would only time out; it is retried once it is back.
    if row.get('PowerState') != 'On' or row.get('NetworkStatus') != 'Reachable':
        return CLEANUP_SKIPPED

    if time.monotonic() >= deadline:
        return CLEANUP_DEFERRED

    return cleanup_remote_user(
        hostname, username, row.get('ReturnedLeaseId'), force=True, timeout=SWEEP_COMMAND_TIMEOUT_SECONDS
    )

def audit_sweep_result(row, outcome):
    """Audit what the sweep changed for one host.

    A retry that still cannot clean the host changes nothing, so it is not recorded again
    every two minutes; the expiry that made the host pending already is.
    """
    detail = {'vmid': row.get('VMID'), 'username': row.get('ReturnedUsername'), 'cleanupResult': outcome}
    hostname = row.get('Hostname') or row.get('VMID')

    if row.get('ResultType') == 'Expired':
        audit('vm.release_expired', 'vm', hostname, AUDIT_SUCCESS, detail)
    elif outcome == CLEANUP_COMPLETED:
        audit('vm.cleanup_completed', 'vm', hostname, AUDIT_SUCCESS, detail)

def finalize_vm_drains():
    """Complete drains whose hosts have become unassigned and clean, auditing each one.

    Returns the hosts moved to Maintenance. A database that does not have FinalizeVmDrains
    yet is not an error: CompleteVmCleanup already completes drains on the common path.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC FinalizeVmDrains")
                rows = cursor.fetchall() or []
            conn.commit()
    except DatabaseUnavailable:
        logger.error("Database connection failed while completing drained hosts.")
        return []
    except Exception as e:
        if is_missing_procedure_error(e):
            logger.warning("FinalizeVmDrains is not deployed yet; skipping drain completion.")
        else:
            logger.exception("Could not complete drained hosts.")
        return []

    finalized = [row for row in rows if not is_procedure_error(row)]
    for row in finalized:
        audit('vm.drain_completed', 'vm', row.get('Hostname') or row.get('VMID'), AUDIT_SUCCESS,
              {'vmid': row.get('VMID'), 'vmStatus': row.get('VmStatus')})
    return finalized

@app.route('/api/vms/released', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
@audited('vm.sweep', target_type='fleet')
def return_released_vm_api():
    """Return Released VMs whose grace period has expired, and retry pending cleanups.

    A returned VM stays CleanupPending until its user has been removed from the host, so a
    host that cannot be cleaned now is retried on a later run instead of being handed to the
    next user with the previous session still on it. Cleanups run in parallel and stop
    starting new work at the deadline, so one slow host cannot hold up the rest.

    Drains whose hosts have become clean are completed afterwards. Every host the sweep
    returns, cleans or takes out of rotation is recorded in the audit log.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC ReturnReleasedVms")
                rows = cursor.fetchall()
            conn.commit()

        rows = [row for row in (rows or []) if not is_procedure_error(row)]
        results = []

        if rows:
            deadline = time.monotonic() + SWEEP_DEADLINE_SECONDS
            with ThreadPoolExecutor(max_workers=min(SWEEP_CONCURRENCY, len(rows))) as pool:
                outcomes = list(pool.map(lambda row: _sweep_cleanup(row, deadline), rows))

            tally = {}
            for row, outcome in zip(rows, outcomes):
                if outcome == CLEANUP_COMPLETED and not complete_vm_cleanup(
                    row.get('VMID'), row.get('ReturnedLeaseId'), row.get('ReturnedUsername')
                ):
                    outcome = CLEANUP_FAILED

                tally[outcome] = tally.get(outcome, 0) + 1

                entry = serialize_for_json(row)
                entry['CleanupResult'] = outcome
                entry['CleanupPending'] = outcome not in (CLEANUP_COMPLETED, CLEANUP_NOT_REQUIRED)
                results.append(entry)
                audit_sweep_result(row, outcome)

            logger.info(
                "Released VM sweep processed %s row(s): %s.",
                len(results), ', '.join(f"{key}={value}" for key, value in sorted(tally.items()))
            )

        drained = finalize_vm_drains()
        g.audit_detail = {'processed': len(results), 'drainsCompleted': len(drained)}

        return jsonify(results), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while returning released VMs.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to return released VMs.")
        return error_response("Unable to return released virtual machines.", 500)


@app.route('/api/vms/history', methods=['POST'])
@token_required(READ_ROLES)
def get_vm_history():
    return run_history_query(
        proc='GetVmHistory',
        paged_proc='GetVmHistoryPaged',
        label='VM history',
    )

# ===============================
# Host Actions APIs
#
# Real power actions and drain, so no admin workflow needs the "Update attributes" repair
# tool. Each action records the intended state in SQL first, exactly as scaling does, and
# then asks Azure; if Azure refuses, the recorded state is put back. The API does not wait
# for Azure to finish: the power-state sync and the reachability probe converge the record.

POWER_ACTION_VERBS = {'Start': 'start', 'Stop': 'stop', 'Restart': 'restart'}


def get_compute_client():
    return ComputeManagementClient(credential=get_azure_credential(), subscription_id=VM_SUBSCRIPTION_ID)


def _vm_is_assigned(vm):
    return bool(vm.get('Username') or vm.get('LeaseId') or vm.get('VmStatus') in ('CheckedOut', 'Released'))


def revert_refused_power_action(vmid, hostname, row):
    """Put back what BeginVmPowerAction recorded, including an assignment a refused stop ended.

    Returns whether the assignment was given back, or None when the recorded state could not
    be restored at all.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC RevertVmPowerAction @VMID = %s, @PreviousPowerState = %s, @PreviousNetworkStatus = %s, "
                    "@EndedAssignment = %s, @PreviousVmStatus = %s, @Username = %s, @AvdHost = %s, "
                    "@LeaseId = %s, @ReleasedDate = %s",
                    (
                        vmid,
                        row.get('PreviousPowerState'),
                        row.get('PreviousNetworkStatus'),
                        bool(row.get('EndedAssignment')),
                        row.get('PreviousVmStatus'),
                        row.get('Username'),
                        row.get('AvdHost'),
                        row.get('PreviousLeaseId'),
                        row.get('PreviousReleasedDate'),
                    )
                )
                reverted = cursor.fetchone()
            conn.commit()
    except Exception:
        logger.exception("Could not restore the recorded state of %s.", hostname)
        return None

    if not reverted or reverted.get('Result') != 'Reverted':
        logger.error("RevertVmPowerAction returned %s for VM %s.", (reverted or {}).get('Result'), vmid)
        return None
    return bool(reverted.get('AssignmentRestored'))


def run_power_action(vmid, action):
    """Start, stop or restart one host for an operator.

    A host with a user assigned can only be stopped or restarted by an administrator who
    confirms its hostname, because the user's session ends. Stopping it also ends the
    assignment (see BeginVmPowerAction), so the user gets a working host when they next
    connect instead of this powered-off one.
    """
    verb = POWER_ACTION_VERBS[action]
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return error_response("Configuration error: missing Azure subscription or resource group.", 500)

        body = request.get_json(silent=True)
        body = body if isinstance(body, dict) else {}

        mode = None
        if action == 'Stop':
            try:
                mode = parse_stop_mode(body.get('mode'))
            except RuleValidationError:
                return error_response("mode must be PowerOff or Deallocate.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVmDetails @VMID = %s", (vmid,))
                vm = cursor.fetchone()

        if not vm:
            return error_response(f"VM with VMID {vmid} was not found.", 404)

        hostname = vm.get('Hostname')
        g.audit_target_id = hostname
        allow_assigned = False

        if action in ('Stop', 'Restart') and _vm_is_assigned(vm):
            user = vm.get('Username') or 'a user'
            g.audit_detail = {'username': vm.get('Username')}

            if not caller_is_admin():
                return error_response(
                    f"{hostname} is assigned to {user}. Only an administrator can {verb} a host that is in use.", 403
                )

            if str(body.get('confirm') or '').strip().lower() != str(hostname or '').lower():
                return jsonify({
                    'error': f"{hostname} is assigned to {user}. Send its hostname as confirm to {verb} it anyway.",
                    'requiresConfirmation': True,
                    'Hostname': hostname,
                    'Username': vm.get('Username'),
                }), 409

            allow_assigned = True

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC BeginVmPowerAction @VMID = %s, @Action = %s, @AllowAssigned = %s",
                    (vmid, action, allow_assigned)
                )
                row = cursor.fetchone()
            conn.commit()

        result = (row or {}).get('Result')
        if result == 'NotFound' or not row:
            return error_response(f"VM with VMID {vmid} was not found.", 404)
        if result == 'Assigned':
            return error_response(f"{hostname} was just assigned to {row.get('Username') or 'a user'}. Refresh and try again.", 409)
        if result == 'InvalidState':
            return error_response(f"{hostname} is powered off. Start it instead of restarting it.", 409)
        if result != 'Requested':
            logger.error("BeginVmPowerAction returned %s for VM %s.", result, vmid)
            return error_response(f"Unable to {verb} the virtual machine.", 500)

        stop_mode = (mode or row.get('StopMode') or 'PowerOff') if action == 'Stop' else None
        ended_assignment = bool(row.get('EndedAssignment'))
        g.audit_detail = {
            'previousPowerState': row.get('PreviousPowerState'),
            'username': row.get('Username'),
            'endedAssignment': ended_assignment,
        }
        if stop_mode:
            g.audit_detail['mode'] = stop_mode

        try:
            virtual_machines = get_compute_client().virtual_machines
            if action == 'Start':
                virtual_machines.begin_start(VM_RESOURCE_GROUP, hostname)
            elif action == 'Restart':
                virtual_machines.begin_restart(VM_RESOURCE_GROUP, hostname)
            elif stop_mode == 'Deallocate':
                virtual_machines.begin_deallocate(VM_RESOURCE_GROUP, hostname)
            else:
                virtual_machines.begin_power_off(VM_RESOURCE_GROUP, hostname)
        except Exception:
            logger.exception("Azure refused to %s %s.", verb, hostname)
            restored = revert_refused_power_action(vmid, hostname, row)
            g.audit_detail['stateRestored'] = restored is not None
            if restored is None:
                message = (f"Azure refused to {verb} {hostname}, and the broker could not restore its recorded state. "
                           "Check the host before trying again.")
            elif ended_assignment and not restored:
                g.audit_detail['assignmentRestored'] = False
                message = (f"Azure refused to stop {hostname}. Its power state was restored, but "
                           f"{row.get('Username') or 'the user'}'s assignment could not be, so it stays ended.")
            else:
                if ended_assignment:
                    g.audit_detail['assignmentRestored'] = True
                message = f"Azure refused to {verb} {hostname}. Its recorded state was restored."
            return error_response(message, 502)

        if action == 'Start':
            message = f"Start requested for {hostname}. It is offered to users once it is reachable."
        elif action == 'Restart':
            message = f"Restart requested for {hostname}."
        elif ended_assignment:
            message = (f"Stop requested for {hostname}. {row.get('Username') or 'The user'}'s assignment ended; "
                       "they get another host when they reconnect.")
        else:
            message = f"Stop requested for {hostname}."

        response = {
            'VMID': vmid,
            'Hostname': hostname,
            'Action': action,
            'PreviousPowerState': row.get('PreviousPowerState'),
            'EndedAssignment': ended_assignment,
            'message': message,
        }
        if stop_mode:
            response['Mode'] = stop_mode
        return jsonify(response), 202

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while requesting %s of VM %s.", verb, vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to %s VM %s.", verb, vmid)
        return error_response(f"Unable to {verb} the virtual machine.", 500)


@app.route('/api/vms/<int:vmid>/start', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.start', target_type='vm', target_param='vmid')
def start_vm(vmid):
    return run_power_action(vmid, 'Start')


@app.route('/api/vms/<int:vmid>/stop', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.stop', target_type='vm', target_param='vmid')
def stop_vm(vmid):
    return run_power_action(vmid, 'Stop')


@app.route('/api/vms/<int:vmid>/restart', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.restart', target_type='vm', target_param='vmid')
def restart_vm(vmid):
    return run_power_action(vmid, 'Restart')


DRAIN_MESSAGES = {
    'Draining': "{hostname} is draining. {user} keeps the session and can reconnect; no one new is assigned. "
                "It moves to maintenance when the assignment ends.",
    'Drained': "{hostname} had no user, so it is in maintenance now.",
    'ReturnedToService': "{hostname} is back in service.",
}


def set_vm_drain(vmid, enabled):
    verb = 'drain' if enabled else 'return to service'
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC SetVmDrain @VMID = %s, @Enabled = %s", (vmid, enabled))
                row = cursor.fetchone()
            conn.commit()

        result = (row or {}).get('Result')
        if not row or result == 'NotFound':
            return error_response(f"VM with VMID {vmid} was not found.", 404)

        hostname = row.get('Hostname')
        g.audit_target_id = hostname
        g.audit_detail = {'result': result, 'username': row.get('Username')}

        if result == 'InvalidState':
            return error_response(f"{hostname} is in a state drain cannot change. Repair its status first.", 409)

        template = DRAIN_MESSAGES.get(result)
        if template:
            message = template.format(hostname=hostname, user=row.get('Username') or 'The current user')
        elif enabled:
            message = f"{hostname} is already out of rotation."
        else:
            message = f"{hostname} is already in service."

        return jsonify(serialize_for_json({
            'VMID': row.get('VMID'),
            'Hostname': hostname,
            'VmStatus': row.get('VmStatus'),
            'DrainRequested': bool(row.get('DrainRequested')),
            'Result': result,
            'message': message,
        })), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while trying to %s VM %s.", verb, vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to %s VM %s.", verb, vmid)
        return error_response(f"Unable to {verb} the virtual machine.", 500)


@app.route('/api/vms/<int:vmid>/drain', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.drain', target_type='vm', target_param='vmid')
def drain_vm(vmid):
    """Stop offering a host to new users without disturbing the one it has."""
    return set_vm_drain(vmid, True)


@app.route('/api/vms/<int:vmid>/undrain', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.undrain', target_type='vm', target_param='vmid')
def undrain_vm(vmid):
    """Return a drained or draining host to service."""
    return set_vm_drain(vmid, False)


@app.route('/api/vms/sync', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('vm.power_sync', target_type='fleet')
def sync_power_states():
    """Correct the recorded power state of every host from Azure now, as scaling does first."""
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return error_response("Configuration error: missing Azure subscription or resource group.", 500)

        try:
            corrections, failed = sync_vm_power_states(get_compute_client())
        except DatabaseUnavailable:
            raise
        except Exception:
            logger.exception("Could not read power states from Azure.")
            return error_response("Azure could not be read. Try again shortly.", 502)

        g.audit_detail = {'corrections': len(corrections), 'failed': bool(failed)}

        if corrections:
            message = f"Corrected the power state of {len(corrections)} host(s) to match Azure."
        else:
            message = "Every host's recorded power state already matches Azure."
        if failed:
            message += " Some hosts could not be read and were left as they were."

        return jsonify({
            'PowerStateCorrections': corrections,
            'PowerSyncFailed': bool(failed),
            'message': message,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while syncing power states.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to sync power states.")
        return error_response("Unable to sync power states.", 500)

# ===============================
# Scaling APIs

@app.route('/api/scaling/log', methods=['POST'])
@token_required(READ_ROLES)
def get_scaling_activity_log():
    return run_history_query(
        proc='GetScalingActivityLog',
        paged_proc='GetScalingActivityLogPaged',
        label='scaling activity log',
    )

AZURE_POWER_STATES_ON = ('PowerState/running', 'PowerState/starting')
AZURE_POWER_STATES_OFF = ('PowerState/stopped', 'PowerState/stopping', 'PowerState/deallocated', 'PowerState/deallocating')
POWER_SYNC_CONCURRENCY = 8
POWER_SYNC_DEADLINE_SECONDS = 30

def azure_power_state(instance_view):
    """Map an Azure instance view to the broker's On/Off, or None when it has no power status."""
    for status in (getattr(instance_view, 'statuses', None) or []):
        code = str(getattr(status, 'code', '') or '')
        if code in AZURE_POWER_STATES_ON:
            return 'On'
        if code in AZURE_POWER_STATES_OFF:
            return 'Off'
    return None

def read_azure_power_states(compute_client, hostnames):
    """Ask Azure for the power state of each registered host.

    Returns (states, failed) where failed is the number of hosts that could not be read.
    virtual_machines.list cannot expand instance views for standalone VMs, so each VM's
    instance view is read individually, in parallel.
    """
    deadline = time.monotonic() + POWER_SYNC_DEADLINE_SECONDS

    def read(hostname):
        if time.monotonic() >= deadline:
            return hostname, None, True
        try:
            view = compute_client.virtual_machines.instance_view(VM_RESOURCE_GROUP, hostname)
            return hostname, azure_power_state(view), False
        except Exception as e:
            if getattr(e, 'status_code', None) == 404:
                # Registered in the broker but not a VM in this resource group.
                return hostname, None, False
            logger.warning("Could not read the power state of %s (%s).", hostname, type(e).__name__)
            return hostname, None, True

    with ThreadPoolExecutor(max_workers=min(POWER_SYNC_CONCURRENCY, len(hostnames))) as pool:
        results = list(pool.map(read, hostnames))

    states = [{'hostname': hostname, 'powerState': state} for hostname, state, _ in results if state]
    failed = sum(1 for _, _, did_fail in results if did_fail)
    return states, failed

def sync_vm_power_states(compute_client):
    """Correct the broker's PowerState from Azure before scaling decides anything.

    Returns (corrections, failed). Without this, a VM started or stopped outside the broker,
    or a start that failed after it was requested, stayed wrong in the database forever.
    """
    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetVms")
            vms = cursor.fetchall() or []

    hostnames = sorted({vm.get('Hostname') for vm in vms if vm.get('Hostname')})
    if not hostnames:
        return [], False

    states, failed = read_azure_power_states(compute_client, hostnames)

    corrections = []
    if states:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC SyncVmPowerStates @PowerStatesJson = %s", (json.dumps(states),))
                corrections = cursor.fetchall() or []
            conn.commit()

    for row in corrections:
        logger.info(
            "Corrected the power state of %s from %s to %s to match Azure.",
            row.get('Hostname'), row.get('PreviousPowerState'), row.get('PowerState')
        )
        # Something outside the broker started or stopped this VM, or a requested operation
        # never happened. Either way an operator will want to know when and which.
        audit('vm.power_corrected', 'vm', row.get('Hostname'), AUDIT_SUCCESS, {
            'vmid': row.get('VMID'),
            'from': row.get('PreviousPowerState'),
            'to': row.get('PowerState'),
        })

    return [{'Hostname': row.get('Hostname'), 'PowerState': row.get('PowerState')} for row in corrections], failed > 0

def revert_power_action(row, previous_power_state):
    """Put a VM's recorded state back after Azure refused the power operation."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC UpdateVmAttributes @VMID = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s",
                    (row.get('VMID'), previous_power_state, row.get('PreviousNetworkStatus'), None)
                )
                cursor.fetchone()
            conn.commit()
    except Exception:
        logger.exception("Could not restore the recorded state of %s.", row.get('VMName'))

def append_scaling_note(activity_id, note):
    if not activity_id:
        return
    try:
        with db_connection() as conn:
            with conn.cursor() as cursor:
                cursor.execute("EXEC AppendScalingActivityNote @ActivityID = %s, @Note = %s", (activity_id, note))
            conn.commit()
    except Exception:
        logger.exception("Could not append a note to scaling activity %s.", activity_id)

@app.route('/api/scaling/trigger', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
@audited('scaling.trigger', target_type='fleet')
def trigger_scaling_logic():
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return error_response("Configuration error: missing Azure subscription or resource group.", 500)

        compute_client = ComputeManagementClient(credential=get_azure_credential(), subscription_id=VM_SUBSCRIPTION_ID)

        # Power operations are idempotent, so if Azure cannot be read the run still goes
        # ahead on the recorded states; the next run corrects anything that drifted.
        try:
            corrections, power_sync_failed = sync_vm_power_states(compute_client)
        except DatabaseUnavailable:
            raise
        except Exception:
            logger.exception("Could not reconcile power states from Azure; scaling continues with the recorded states.")
            corrections, power_sync_failed = [], True

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC TriggerScalingLogic")
                rows = cursor.fetchall() or []
            # TriggerScalingLogic updates PowerState on the selected VMs and inserts
            # the activity-log row. pymssql does not autocommit, so without this the
            # database rolled all of it back while the Azure power operations below
            # still went ahead.
            conn.commit()

        powered_on_vms = []
        powered_off_vms = []
        deallocated_vms = []
        failed = []

        for row in rows:
            vm_name = row.get('VMName')
            action = row.get('ActionType')
            if not vm_name:
                continue

            # PoweredOn/PoweredOff is what the procedure emitted before it was fixed, and
            # the old mismatch meant scaling never actually started or stopped anything.
            if action in ('PowerOn', 'PoweredOn'):
                try:
                    compute_client.virtual_machines.begin_start(VM_RESOURCE_GROUP, vm_name)
                    powered_on_vms.append(vm_name)
                    audit('scaling.power_on', 'vm', vm_name, AUDIT_SUCCESS, {'activityId': row.get('ActivityID')})
                except Exception:
                    logger.exception("Azure refused to start %s.", vm_name)
                    revert_power_action(row, 'Off')
                    append_scaling_note(row.get('ActivityID'), f"Starting {vm_name} failed, so it was recorded as off again.")
                    failed.append({'VMName': vm_name, 'Action': 'PowerOn', 'Error': 'The Azure start operation could not be requested.'})
                    audit('scaling.power_on', 'vm', vm_name, AUDIT_FAILURE, {
                        'activityId': row.get('ActivityID'),
                        'error': 'The Azure start operation could not be requested.',
                    })
            elif action in ('PowerOff', 'PoweredOff'):
                deallocate = (row.get('StopMode') or 'PowerOff') == 'Deallocate'
                audit_action = 'scaling.deallocate' if deallocate else 'scaling.power_off'
                try:
                    if deallocate:
                        compute_client.virtual_machines.begin_deallocate(VM_RESOURCE_GROUP, vm_name)
                        deallocated_vms.append(vm_name)
                    else:
                        compute_client.virtual_machines.begin_power_off(VM_RESOURCE_GROUP, vm_name)
                        powered_off_vms.append(vm_name)
                    audit(audit_action, 'vm', vm_name, AUDIT_SUCCESS, {'activityId': row.get('ActivityID')})
                except Exception:
                    logger.exception("Azure refused to stop %s.", vm_name)
                    revert_power_action(row, 'On')
                    append_scaling_note(row.get('ActivityID'), f"Stopping {vm_name} failed, so it was recorded as running again.")
                    failed.append({
                        'VMName': vm_name,
                        'Action': 'Deallocate' if deallocate else 'PowerOff',
                        'Error': 'The Azure stop operation could not be requested.',
                    })
                    audit(audit_action, 'vm', vm_name, AUDIT_FAILURE, {
                        'activityId': row.get('ActivityID'),
                        'error': 'The Azure stop operation could not be requested.',
                    })

        g.audit_detail = {
            'started': len(powered_on_vms),
            'stopped': len(powered_off_vms) + len(deallocated_vms),
            'failed': len(failed),
            'corrections': len(corrections),
        }

        return jsonify({
            'PoweredOnVMs': powered_on_vms,
            'PoweredOffVMs': powered_off_vms,
            'DeallocatedVMs': deallocated_vms,
            'Failed': failed,
            'PowerStateCorrections': corrections,
            'PowerSyncFailed': power_sync_failed,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while triggering scaling logic.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to trigger scaling logic.")
        return error_response("Unable to trigger scaling logic.", 500)

# ===============================
# Scaling Rules APIs

SCALING_RULE_FIELDS = (
    'minvms', 'maxvms', 'scaleupratio', 'scaleupincrement', 'scaledownratio', 'scaledownincrement'
)
STOP_MODES = {'poweroff': 'PowerOff', 'deallocate': 'Deallocate'}


class RuleValidationError(Exception):
    """A scaling rule value the operator must correct. The message names the field."""

    def __init__(self, client_message):
        super().__init__(client_message)
        self.client_message = client_message


def _is_blank(value):
    return value is None or (isinstance(value, str) and value.strip() == '')

def _rule_integer(value, field):
    if isinstance(value, bool):
        raise RuleValidationError(f"{field} must be a whole number.")
    if isinstance(value, float):
        if not value.is_integer():
            raise RuleValidationError(f"{field} must be a whole number.")
        return int(value)
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        raise RuleValidationError(f"{field} must be a whole number.")

def _rule_ratio(value, field):
    if isinstance(value, bool):
        raise RuleValidationError(f"{field} must be a number between 0 and 100.")
    try:
        number = float(str(value).strip())
    except (TypeError, ValueError):
        raise RuleValidationError(f"{field} must be a number between 0 and 100.")
    if number != number or number in (float('inf'), float('-inf')):
        raise RuleValidationError(f"{field} must be a number between 0 and 100.")
    return round(number, 2)

def parse_rule_fields(body):
    """Parse whichever rule fields are present, leaving absent ones out."""
    rule = {}
    for field in SCALING_RULE_FIELDS:
        value = body.get(field)
        if _is_blank(value):
            continue
        rule[field] = _rule_ratio(value, field) if field.endswith('ratio') else _rule_integer(value, field)
    return rule

def parse_stop_mode(value):
    if _is_blank(value):
        return None
    if not isinstance(value, str) or value.strip().lower() not in STOP_MODES:
        raise RuleValidationError("stopmode must be PowerOff or Deallocate.")
    return STOP_MODES[value.strip().lower()]

def validate_rule(rule):
    """Check a complete rule. Mirrors the CHECK constraints on dbo.VmScalingRules.

    A minimum of zero is rejected because a pool with no running host cannot recover:
    nothing starts a VM until a checkout succeeds, and no checkout can succeed.
    """
    if rule['minvms'] < 1:
        raise RuleValidationError("minvms must be at least 1.")
    if rule['maxvms'] <= rule['minvms']:
        raise RuleValidationError("maxvms must be greater than minvms.")
    for field in ('scaleupratio', 'scaledownratio'):
        if not 0 <= rule[field] <= 100:
            raise RuleValidationError(f"{field} must be between 0 and 100.")
    if rule['scaleupratio'] <= rule['scaledownratio']:
        raise RuleValidationError("scaleupratio must be greater than scaledownratio.")
    for field in ('scaleupincrement', 'scaledownincrement'):
        if rule[field] < 1:
            raise RuleValidationError(f"{field} must be at least 1.")

def _rule_from_row(row):
    return {
        'minvms': int(row['MinVMs']),
        'maxvms': int(row['MaxVMs']),
        'scaleupratio': float(row['ScaleUpRatio']),
        'scaleupincrement': int(row['ScaleUpIncrement']),
        'scaledownratio': float(row['ScaleDownRatio']),
        'scaledownincrement': int(row['ScaleDownIncrement']),
    }

@app.route('/api/scaling/rules', methods=['GET'])
@token_required(READ_ROLES)
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

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while listing scaling rules.")
        return database_unavailable_response(e)
    except Exception:
        logger.exception("Failed to list scaling rules.")
        return error_response("Unable to retrieve scaling rules.", 500)

@app.route('/api/scaling/rules/<int:ruleid>', methods=['GET'])
@token_required(READ_ROLES)
def get_scaling_rule_details(ruleid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetScalingRuleDetails @RuleID = %s", (ruleid,))
                row = cursor.fetchone()

        if not row:
            return error_response(f"Scaling rule with RuleID {ruleid} was not found.", 404)

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading scaling rule %s.", ruleid)
        return database_unavailable_response(e)
    except Exception:
        logger.exception("Failed to read scaling rule %s.", ruleid)
        return error_response("Unable to retrieve the scaling rule.", 500)

@app.route('/api/scaling/rules/create', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('scaling.rule_create', target_type='rule')
def create_scaling_rule():
    try:
        req_body = request.get_json(silent=True) or {}

        if any(_is_blank(req_body.get(field)) for field in SCALING_RULE_FIELDS):
            return error_response(
                "Please provide all required fields: 'minvms', 'maxvms', 'scaleupratio', "
                "'scaleupincrement', 'scaledownratio', 'scaledownincrement'.",
                400
            )

        try:
            rule = parse_rule_fields(req_body)
            validate_rule(rule)
            stop_mode = parse_stop_mode(req_body.get('stopmode'))
        except RuleValidationError as e:
            return error_response(e.client_message, 400)

        g.audit_detail = {'rule': rule, 'stopMode': stop_mode or 'PowerOff'}

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    """
                    EXEC CreateScalingRule @MinVMs = %s, @MaxVMs = %s, @ScaleUpRatio = %s,
                                        @ScaleUpIncrement = %s, @ScaleDownRatio = %s, @ScaleDownIncrement = %s,
                                        @StopMode = %s
                    """,
                    (rule['minvms'], rule['maxvms'], rule['scaleupratio'], rule['scaleupincrement'],
                     rule['scaledownratio'], rule['scaledownincrement'], stop_mode),
                )
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response("Failed to create the scaling rule. Please try again.", 500)

        new_rule_id = row.get('NewRuleID')
        if new_rule_id is None:
            message = str(row.get('Message') or '')
            if 'busy' in message.lower():
                return error_response("Scaling rules are busy. Please try again.", 503)

            active_rule_id = row.get('ActiveRuleID')
            active_rule_id = int(active_rule_id) if active_rule_id is not None else None
            text = (
                f"Only one scaling rule is applied. Edit rule #{active_rule_id} instead."
                if active_rule_id is not None else "Only one scaling rule is applied."
            )
            return jsonify({'error': text, 'ActiveRuleID': active_rule_id}), 409

        g.audit_target_id = int(new_rule_id)
        return jsonify({"NewRuleID": int(new_rule_id)}), 201

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while creating a scaling rule.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to create a scaling rule.")
        return error_response("Unable to create the scaling rule.", 500)

@app.route('/api/scaling/rules/<int:ruleid>/update', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('scaling.rule_update', target_type='rule', target_param='ruleid')
def update_scaling_rule(ruleid):
    try:
        req_body = request.get_json(silent=True) or {}

        try:
            changes = parse_rule_fields(req_body)
            stop_mode = parse_stop_mode(req_body.get('stopmode'))
        except RuleValidationError as e:
            return error_response(e.client_message, 400)

        if not changes and stop_mode is None:
            return error_response("Please provide at least one field to update.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetScalingRuleDetails @RuleID = %s", (ruleid,))
                current = cursor.fetchone()

        if not current:
            return error_response(f"Scaling rule with RuleID {ruleid} was not found.", 404)

        # Updates are partial, so the rule that results from them is what gets validated.
        # That also turns a CHECK constraint violation into a 400 that names the field.
        merged = _rule_from_row(current)
        previous = dict(merged)
        merged.update(changes)
        g.audit_detail = {
            'changes': {
                field: {'from': previous[field], 'to': value}
                for field, value in changes.items() if previous.get(field) != value
            },
        }
        if stop_mode is not None and stop_mode != (current.get('StopMode') or 'PowerOff'):
            g.audit_detail['changes']['stopmode'] = {'from': current.get('StopMode') or 'PowerOff', 'to': stop_mode}
        try:
            validate_rule(merged)
        except RuleValidationError as e:
            return error_response(e.client_message, 400)

        with db_connection() as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    EXEC UpdateScalingRule @RuleID = %s, @MinVMs = %s, @MaxVMs = %s, @ScaleUpRatio = %s,
                                        @ScaleUpIncrement = %s, @ScaleDownRatio = %s, @ScaleDownIncrement = %s,
                                        @StopMode = %s
                    """,
                    (ruleid, merged['minvms'], merged['maxvms'], merged['scaleupratio'], merged['scaleupincrement'],
                     merged['scaledownratio'], merged['scaledownincrement'], stop_mode),
                )
            conn.commit()

        return jsonify({'message': f"Scaling rule with RuleID {ruleid} updated successfully.", 'RuleID': ruleid}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while updating scaling rule %s.", ruleid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to update scaling rule %s.", ruleid)
        return error_response("Unable to update the scaling rule.", 500)

@app.route('/api/scaling/rules/<int:ruleid>/delete', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('scaling.rule_delete', target_type='rule', target_param='ruleid')
def delete_scaling_rule(ruleid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteScalingRule @RuleID = %s", (ruleid,))
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"Scaling rule with RuleID {ruleid} could not be deleted or was not found.", 404)

        return jsonify({'message': f"Scaling rule with RuleID {ruleid} has been successfully deleted.", 'RuleID': ruleid}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while deleting scaling rule %s.", ruleid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to delete scaling rule %s.", ruleid)
        return error_response("Unable to delete the scaling rule.", 500)

@app.route('/api/scaling/rules/history', methods=['POST'])
@token_required(READ_ROLES)
def get_scaling_rules_history():
    return run_history_query(
        proc='GetVMScalingRulesHistory',
        paged_proc='GetVmScalingRulesHistoryPaged',
        label='scaling rules history',
    )

# ===============================
# Linux Host Settings APIs

@app.route('/api/hosts/settings', methods=['GET'])
@token_required(READ_ROLES + [ROLE_LINUX_HOST, ROLE_SCHEDULED_TASK], required_group_ids=[LINUX_HOST_GROUP_ID])
def get_host_settings():
    """Return the fleet-wide settings profile.

    This is the pull side of settings delivery. The Linux host agents already hold the
    LinuxHost role, so they can read this with no additional Entra configuration. Host
    agents and other managed identities get the host document, which leaves out settings a
    host that has not been migrated would reject; portal users always see every setting.
    """
    try:
        settings = fetch_host_settings()
        if settings is None:
            return jsonify({'error': 'Unable to read Linux host settings.'}), 500

        return jsonify(settings if is_delegated_caller() else host_settings_document(settings)), 200

    except Exception:
        # Detail goes to Application Insights rather than the response body; returning the
        # exception text would expose internal state to the caller.
        logger.exception("Failed to read Linux host settings.")
        return jsonify({'error': 'Unable to read Linux host settings.'}), 500

@app.route('/api/hosts/settings/update', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('settings.update', target_type='settings')
def update_host_settings():
    try:
        g.audit_target_id = 'Global'
        payload = request.get_json(silent=True) or {}
        if not isinstance(payload, dict):
            return jsonify({'error': 'Settings payload must be a JSON object.'}), 400

        updated_by = payload.pop('updatedBy', None)
        # A portal user is recorded as themselves, from their validated token, rather than
        # from whatever name the caller put in the body.
        _actor_oid, actor_name, actor_type = audit_actor()
        if actor_type == AUDIT_ACTOR_USER and actor_name:
            updated_by = actor_name

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
        g.audit_detail = {
            'changes': {
                field: {'from': current.get(field), 'to': value}
                for field, value in settings.items() if current.get(field) != value
            },
            'previousVersion': current.get('SettingsVersion'),
        }

        if resulting['IdleTimeoutSeconds'] != 0 and resulting['IdleWarningSeconds'] >= resulting['IdleTimeoutSeconds']:
            return jsonify({
                'error': (
                    'IdleWarningSeconds must be less than IdleTimeoutSeconds so users are warned '
                    'before they are disconnected.'
                )
            }), 400

        if resulting.get('PreserveSessionsOnDisconnect') and resulting.get('ScreenLockEnabled'):
            return jsonify({
                'error': (
                    'PreserveSessionsOnDisconnect cannot be combined with ScreenLockEnabled. A resumed '
                    'session behind a lock screen cannot be unlocked, because users never know the '
                    'password the broker rotates at every checkout.'
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
                    "@PreserveSessionsOnDisconnect = %s, "
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
                        settings.get('PreserveSessionsOnDisconnect'),
                        updated_by
                    )
                )
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return jsonify({'error': 'Unable to update Linux host settings.'}), 500

        saved = normalize_host_settings(row)
        g.audit_detail['settingsVersion'] = saved.get('SettingsVersion')
        return jsonify(saved), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while updating Linux host settings.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to update Linux host settings.")
        return jsonify({'error': 'Unable to update Linux host settings.'}), 500

@app.route('/api/hosts/settings/apply', methods=['POST'])
@token_required(OPERATE_ROLES + [ROLE_SCHEDULED_TASK])
@audited('settings.apply', target_type='settings')
def apply_host_settings():
    """Push the current settings profile to hosts over SSH.

    This is only the fast path. The host agents converge on their own through the pull
    endpoint, so a host that is unreachable here, or that the push does not reach before
    the deadline, is not left permanently stale; it picks the settings up on its next
    reconcile run.
    """
    try:
        payload = request.get_json(silent=True) or {}
        requested_hostnames = payload.get('hostnames') if isinstance(payload, dict) else None

        if requested_hostnames is not None and not isinstance(requested_hostnames, list):
            return jsonify({'error': 'hostnames must be a list.'}), 400

        settings = fetch_host_settings()
        if settings is None:
            return jsonify({'error': 'Unable to read Linux host settings.'}), 500

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                vms = cursor.fetchall() or []

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

        hostnames = sorted({vm.get('Hostname') for vm in targets if vm.get('Hostname')}, key=str.lower)
        deadline = time.monotonic() + APPLY_DEADLINE_SECONDS

        def push(hostname):
            if time.monotonic() >= deadline:
                return hostname, None, None
            applied, message = apply_host_settings_to_host(hostname, settings, timeout=APPLY_HOST_TIMEOUT_SECONDS)
            return hostname, applied, message

        outcomes = []
        if hostnames:
            with ThreadPoolExecutor(max_workers=min(APPLY_CONCURRENCY, len(hostnames))) as pool:
                outcomes = list(pool.map(push, hostnames))

        results = []
        not_attempted = []
        succeeded = 0

        for hostname, applied, message in outcomes:
            if applied is None:
                not_attempted.append(hostname)
                continue
            if applied:
                succeeded += 1
            results.append({
                'Hostname': hostname,
                'Applied': applied,
                'Message': message
            })

        g.audit_target_id = ', '.join(hostnames) if requested_hostnames and len(hostnames) <= 5 else 'Fleet'
        g.audit_detail = {
            'settingsVersion': settings['SettingsVersion'],
            'targetCount': len(hostnames),
            'succeeded': succeeded,
            'notAttempted': len(not_attempted),
        }

        return jsonify({
            'SettingsVersion': settings['SettingsVersion'],
            'TargetCount': len(hostnames),
            'SucceededCount': succeeded,
            'Results': results,
            'NotAttempted': not_attempted,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while pushing Linux host settings.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to push Linux host settings.")
        return jsonify({'error': 'Unable to push Linux host settings.'}), 500

@app.route('/api/hosts/<hostname>/settings/ack', methods=['POST'])
@token_required([ROLE_LINUX_HOST, ROLE_ADMIN], required_group_ids=[LINUX_HOST_GROUP_ID])
def acknowledge_host_settings(hostname):
    """Record the settings version a host has applied, so the portal can show drift."""
    try:
        payload = request.get_json(silent=True) or {}
        raw_version = payload.get('settingsVersion') if isinstance(payload, dict) else None

        try:
            settings_version = int(raw_version)
        except (TypeError, ValueError):
            return jsonify({'error': 'settingsVersion must be an integer.'}), 400

        if settings_version < 1:
            return jsonify({'error': 'settingsVersion must be a positive integer.'}), 400

        if not record_settings_applied(hostname, settings_version):
            return jsonify({'error': f"No VM found with Hostname {hostname}."}), 404

        return jsonify({'Hostname': hostname, 'SettingsVersion': settings_version}), 200

    except Exception:
        logger.exception("Failed to record the applied settings version for %s.", hostname)
        return jsonify({'error': 'Unable to record the applied settings version.'}), 500

@app.route('/api/hosts/settings/history', methods=['GET'])
@token_required(READ_ROLES)
def get_host_settings_history():
    """Every saved version of the host settings profile, newest first, with who saved it."""
    try:
        limit = coerce_optional_int(request.args.get('limit'), default=50, minimum=1, maximum=200)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetLinuxHostSettingsHistory @Limit = %s", (limit,))
                rows = cursor.fetchall() or []

        versions = []
        for row in rows:
            version = {field: int(row[field]) for field in LINUX_HOST_SETTING_BOUNDS if row.get(field) is not None}
            version.update({field: bool(row.get(field)) for field in LINUX_HOST_SETTING_BOOLEANS})
            version.update({
                'SettingsVersion': int(row.get('SettingsVersion') or 0),
                'UpdatedBy': row.get('UpdatedBy'),
                'ValidFromUtc': row.get('ValidFromUtc'),
                'ValidToUtc': row.get('ValidToUtc'),
                'IsCurrent': bool(row.get('IsCurrent')),
            })
            versions.append(version)

        return jsonify(versions), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading the host settings history.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read the host settings history.")
        return error_response("Unable to retrieve the host settings history.", 500)

# ===============================
# Host Heartbeat and Fleet Health APIs
#
# Each Linux host agent posts a heartbeat at the end of every timer run: its agent and script
# versions, OS, desktop, xrdp and NFS state, load, memory, disk and sessions. Fleet health
# reports on it only. Readiness is still decided by the reachability probe, so a broken
# heartbeat path can never take hosts out of rotation.

HEARTBEAT_HOSTNAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
HEARTBEAT_VERSION_RE = re.compile(r'^[0-9A-Za-z][0-9A-Za-z.+~_-]{0,31}$')
HEARTBEAT_TOKEN_RE = re.compile(r'^[0-9A-Za-z][0-9A-Za-z.+~_:-]*$')
HEARTBEAT_USERNAME_RE = re.compile(r'^[A-Za-z0-9_]{1,64}$')
HEARTBEAT_SCRIPTS = (
    'release-session.sh', 'logind-session-watcher.sh', 'xrdp-who-xorg.sh',
    'create-user.sh', 'manage-lease.sh', 'apply-host-settings.sh', 'session-control.sh',
)
HEARTBEAT_DESKTOPS = ('gnome', 'xfce', 'mate', 'kde', 'other', 'none', 'unknown')
HEARTBEAT_SESSION_STATES = ('active', 'disconnected', 'unknown')
HEARTBEAT_MAX_EPOCH = 2 ** 40

# Health flags, and the summary counter each one feeds.
HEALTH_FLAGS = {
    'no-heartbeat': 'NoHeartbeat',
    'stale': 'Stale',
    'xrdp-down': 'XrdpDown',
    'nfs-unreachable': 'NfsUnreachable',
    'low-disk': 'LowDisk',
    'agent-outdated': 'AgentOutdated',
    'settings-drift': 'SettingsDrift',
}


def _hb_version(value):
    return value if isinstance(value, str) and HEARTBEAT_VERSION_RE.match(value) else None


def _hb_token(value, max_length):
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value if 0 < len(value) <= max_length and HEARTBEAT_TOKEN_RE.match(value) else None


def _hb_text(value, max_length):
    if not isinstance(value, str):
        return None
    value = ''.join(character for character in value if character.isprintable()).strip()
    return value[:max_length] or None


def _hb_int(value, minimum, maximum):
    if isinstance(value, bool):
        return None
    if isinstance(value, str) and re.fullmatch(r'-?\d{1,19}', value.strip()):
        value = int(value.strip())
    if isinstance(value, float):
        if value != value or value in (float('inf'), float('-inf')):
            return None
        value = int(value)
    if not isinstance(value, int):
        return None
    return value if minimum <= value <= maximum else None


def _hb_float(value, minimum, maximum):
    if isinstance(value, bool):
        return None
    if isinstance(value, str):
        try:
            value = float(value.strip())
        except ValueError:
            return None
    if not isinstance(value, (int, float)):
        return None
    value = float(value)
    if value != value or value in (float('inf'), float('-inf')) or not minimum <= value <= maximum:
        return None
    return round(value, 2)


def _hb_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str) and value.strip().lower() in ('true', 'false'):
        return value.strip().lower() == 'true'
    return None


def _hb_object(value):
    return value if isinstance(value, dict) else {}


def _without_none(document):
    return {key: value for key, value in document.items() if value is not None and value != {}}


def normalize_heartbeat(payload):
    """Keep only the fields the broker understands, each checked and bounded.

    Returns (document, problem). A host is root on itself, so nothing in a heartbeat is
    trusted: unknown keys are dropped, and a value of the wrong type or out of range is
    dropped rather than failing the heartbeat, which still proves the agent is running.
    """
    if not isinstance(payload, dict):
        return None, "The heartbeat must be a JSON object."

    scripts = {}
    for name in HEARTBEAT_SCRIPTS:
        if name in _hb_object(payload.get('scriptVersions')):
            # A script that predates the version constant reports null, which is kept so
            # fleet health can show a partly migrated host.
            scripts[name] = _hb_version(payload['scriptVersions'][name])

    sessions = []
    raw_sessions = payload.get('sessions')
    if isinstance(raw_sessions, list):
        for raw in raw_sessions[:HEARTBEAT_MAX_SESSIONS]:
            if not isinstance(raw, dict):
                continue
            username = raw.get('username')
            if not isinstance(username, str) or not HEARTBEAT_USERNAME_RE.match(username):
                continue
            state = raw.get('state') if raw.get('state') in HEARTBEAT_SESSION_STATES else 'unknown'
            sessions.append({
                'username': username,
                'state': state,
                'sessionStart': _hb_int(raw.get('sessionStart'), 0, HEARTBEAT_MAX_EPOCH),
                'disconnectedSince': _hb_int(raw.get('disconnectedSince'), 0, HEARTBEAT_MAX_EPOCH),
                'idleSeconds': _hb_int(raw.get('idleSeconds'), 0, HEARTBEAT_MAX_EPOCH),
            })

    os_info = _hb_object(payload.get('os'))
    xrdp = _hb_object(payload.get('xrdp'))
    nfs = _hb_object(payload.get('nfs'))
    desktop = payload.get('desktop')

    document = _without_none({
        'agentVersion': _hb_version(payload.get('agentVersion')),
        'scriptVersions': scripts or None,
        'settingsVersion': _hb_int(payload.get('settingsVersion'), 0, 2 ** 31 - 1),
        'os': _without_none({
            'id': _hb_token(os_info.get('id'), 32),
            'version': _hb_token(os_info.get('version'), 32),
            'name': _hb_text(os_info.get('name'), 128),
        }),
        'kernel': _hb_token(payload.get('kernel'), 128),
        'desktop': desktop if desktop in HEARTBEAT_DESKTOPS else None,
        'xrdp': _without_none({'version': _hb_version(xrdp.get('version')), 'active': _hb_bool(xrdp.get('active'))}),
        'nfs': _without_none({'reachable': _hb_bool(nfs.get('reachable')), 'mounts': _hb_int(nfs.get('mounts'), 0, 1000)}),
        'loadAverage': _hb_float(payload.get('loadAverage'), 0, 100000),
        'cpuCount': _hb_int(payload.get('cpuCount'), 0, 4096),
        'memoryAvailableMb': _hb_int(payload.get('memoryAvailableMb'), 0, 64 * 1024 * 1024),
        'memoryTotalMb': _hb_int(payload.get('memoryTotalMb'), 0, 64 * 1024 * 1024),
        'rootDiskFreePct': _hb_int(payload.get('rootDiskFreePct'), 0, 100),
        'uptimeSeconds': _hb_int(payload.get('uptimeSeconds'), 0, HEARTBEAT_MAX_EPOCH),
    })
    # An empty list is kept: it means "no sessions", which differs from "not reported".
    if isinstance(raw_sessions, list):
        document['sessions'] = sessions

    return document, None


@app.route('/api/hosts/<hostname>/heartbeat', methods=['POST'])
@token_required([ROLE_LINUX_HOST, ROLE_ADMIN], required_group_ids=[LINUX_HOST_GROUP_ID])
def record_host_heartbeat(hostname):
    """Store the latest heartbeat from a Linux host agent.

    Not audited: every host sends one each reconcile run. A Linux host's managed identity
    names its VM in xms_mirid, so a host cannot report on another's behalf.
    """
    try:
        if not HEARTBEAT_HOSTNAME_RE.match(hostname or ''):
            return error_response("The hostname is not valid.", 400)

        too_large = f"The heartbeat is larger than {HEARTBEAT_MAX_BYTES} bytes."
        if request.content_length is not None and request.content_length > HEARTBEAT_MAX_BYTES:
            return error_response(too_large, 413)

        raw = request.stream.read(HEARTBEAT_MAX_BYTES + 1)
        if len(raw) > HEARTBEAT_MAX_BYTES:
            return error_response(too_large, 413)

        try:
            payload = json.loads(raw.decode('utf-8')) if raw else None
        except (UnicodeDecodeError, ValueError):
            payload = None

        claims = getattr(g, 'token_claims', None) or {}
        identity = _MIRID_VM_NAME_RE.search(str(claims.get('xms_mirid') or ''))
        if identity and identity.group('name').lower() != hostname.lower():
            logger.warning("Refused a heartbeat for %s from the identity of VM %s.", hostname, identity.group('name'))
            if denial_audit_allowed(claims.get('oid')):
                audit('host.heartbeat', 'vm', hostname, AUDIT_DENIED, {
                    'reason': 'The caller is the identity of a different VM.',
                    'callerVm': identity.group('name'),
                })
            return error_response("A host can only report its own heartbeat.", 403)

        document, problem = normalize_heartbeat(payload)
        if problem:
            return error_response(problem, 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC RecordHostHeartbeat @Hostname = %s, @HeartbeatJson = %s",
                    (hostname, json.dumps(document))
                )
                row = cursor.fetchone()
            conn.commit()

        result = (row or {}).get('Result')
        if result == 'NotFound':
            return error_response(f"No VM found with Hostname {hostname}.", 404)
        if result != 'Recorded':
            logger.error("RecordHostHeartbeat returned %s for %s.", result, hostname)
            return error_response("Unable to record the heartbeat.", 500)

        return jsonify({'Hostname': row.get('Hostname'), 'ReceivedAtUtc': row.get('ReceivedAtUtc')}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while recording a heartbeat from %s.", hostname)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to record a heartbeat from %s.", hostname)
        return error_response("Unable to record the heartbeat.", 500)


def version_tuple(value):
    """'1.2.3' as (1, 2, 3); a suffix such as '-dev' is ignored. None when there is no number."""
    if not isinstance(value, str):
        return None
    numbers = re.findall(r'\d+', re.split(r'[-+]', value, maxsplit=1)[0])
    if not numbers:
        return None
    parts = [int(number) for number in numbers[:4]]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def heartbeat_stale_after(reconcile_interval_seconds):
    try:
        interval = int(reconcile_interval_seconds or LINUX_HOST_SETTING_BOUNDS['ReconcileIntervalSeconds'][2])
    except (TypeError, ValueError):
        interval = LINUX_HOST_SETTING_BOUNDS['ReconcileIntervalSeconds'][2]
    return max(HEARTBEAT_STALE_MINIMUM_SECONDS, HEARTBEAT_STALE_INTERVALS * interval)


def agent_is_outdated(agent_version, script_versions, expected_version):
    """True when the agent, or any one of its scripts, is older than the expected version."""
    expected = version_tuple(expected_version)
    reported = version_tuple(agent_version)
    if reported is None or (expected and reported < expected):
        return True
    for version in (script_versions or {}).values():
        parsed = version_tuple(version)
        if parsed is None or (expected and parsed < expected):
            return True
    return False


def _json_column(value, expected_type):
    if not value:
        return None
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError):
        return None
    return parsed if isinstance(parsed, expected_type) else None


def host_health(row, expected_version):
    """One host's health entry, with the flags an operator needs to act on.

    Heartbeat-derived problems (xrdp, NFS, disk) are only flagged from a heartbeat that is
    still current, because stale data would be misleading. A powered-off host is expected to
    be silent, so it is never flagged as stale or missing a heartbeat.
    """
    power_on = row.get('PowerState') == 'On'
    age = row.get('HeartbeatAgeSeconds')
    stale_after = heartbeat_stale_after(row.get('ReconcileIntervalSeconds'))
    reporting = age is not None and age <= stale_after
    script_versions = _json_column(row.get('ScriptVersionsJson'), dict)

    flags = []
    if power_on:
        if age is None:
            flags.append('no-heartbeat')
        elif not reporting:
            flags.append('stale')

        if reporting:
            if row.get('XrdpActive') is False:
                flags.append('xrdp-down')
            if row.get('NfsReachable') is False:
                flags.append('nfs-unreachable')
            disk = row.get('RootDiskFreePct')
            if disk is not None and disk < LOW_DISK_FREE_PERCENT:
                flags.append('low-disk')

    if age is not None and agent_is_outdated(row.get('AgentVersion'), script_versions, expected_version):
        flags.append('agent-outdated')

    current_version = row.get('CurrentSettingsVersion')
    applied_version = row.get('AppliedSettingsVersion')
    if power_on and current_version and (applied_version is None or applied_version < current_version):
        flags.append('settings-drift')

    load = row.get('LoadAverage')
    return serialize_for_json({
        'VMID': row.get('VMID'),
        'Hostname': row.get('Hostname'),
        'PowerState': row.get('PowerState'),
        'NetworkStatus': row.get('NetworkStatus'),
        'VmStatus': row.get('VmStatus'),
        'DrainRequested': bool(row.get('DrainRequested')),
        'CleanupPending': bool(row.get('CleanupPending')),
        'Username': row.get('Username'),
        'Status': 'off' if not power_on else ('attention' if flags else 'healthy'),
        'Flags': flags,
        'Reporting': reporting,
        'LastHeartbeatUtc': row.get('LastHeartbeatUtc'),
        'HeartbeatAgeSeconds': age,
        'AgentVersion': row.get('AgentVersion'),
        'ScriptVersions': script_versions,
        'AppliedSettingsVersion': applied_version,
        'CurrentSettingsVersion': current_version,
        'OsId': row.get('OsId'),
        'OsVersion': row.get('OsVersion'),
        'OsName': row.get('OsName'),
        'KernelVersion': row.get('KernelVersion'),
        'Desktop': row.get('Desktop'),
        'XrdpVersion': row.get('XrdpVersion'),
        'XrdpActive': row.get('XrdpActive'),
        'NfsReachable': row.get('NfsReachable'),
        'NfsMountCount': row.get('NfsMountCount'),
        'LoadAverage': float(load) if load is not None else None,
        'CpuCount': row.get('CpuCount'),
        'MemoryAvailableMb': row.get('MemoryAvailableMb'),
        'MemoryTotalMb': row.get('MemoryTotalMb'),
        'RootDiskFreePct': row.get('RootDiskFreePct'),
        'UptimeSeconds': row.get('UptimeSeconds'),
        'SessionCount': row.get('SessionCount'),
        'Sessions': _json_column(row.get('SessionsJson'), list) or [],
    })


def summarize_host_health(hosts):
    summary = {'Total': len(hosts), 'PoweredOn': 0, 'Reporting': 0, 'Healthy': 0, 'Attention': 0, 'Off': 0}
    summary.update({counter: 0 for counter in HEALTH_FLAGS.values()})

    for host in hosts:
        if host['Status'] == 'off':
            summary['Off'] += 1
        else:
            summary['PoweredOn'] += 1
            summary['Healthy' if host['Status'] == 'healthy' else 'Attention'] += 1
        if host['Reporting']:
            summary['Reporting'] += 1
        for flag in host['Flags']:
            summary[HEALTH_FLAGS[flag]] += 1

    return summary


@app.route('/api/hosts/health', methods=['GET'])
@token_required(READ_ROLES)
def get_host_health():
    """Every host's latest heartbeat with health flags and a fleet summary.

    ?hostname= narrows it to one host, for the host agent card on a VM's details page.
    ?summary=true leaves the hosts out, for the dashboard, which refreshes every 30 seconds.
    """
    try:
        hostname = (request.args.get('hostname') or '').strip() or None
        if hostname and not HEARTBEAT_HOSTNAME_RE.match(hostname):
            return error_response("The hostname is not valid.", 400)
        summary_only = str(request.args.get('summary') or '').strip().lower() in ('1', 'true', 'yes')

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetHostHealth @Hostname = %s", (hostname,))
                rows = cursor.fetchall() or []

        hosts = [host_health(row, EXPECTED_HOST_AGENT_VERSION) for row in rows]
        first = rows[0] if rows else {}

        body = {
            'ExpectedAgentVersion': EXPECTED_HOST_AGENT_VERSION,
            'CurrentSettingsVersion': first.get('CurrentSettingsVersion'),
            'StaleAfterSeconds': heartbeat_stale_after(first.get('ReconcileIntervalSeconds')),
            'Summary': summarize_host_health(hosts),
        }
        if not summary_only:
            body['Hosts'] = hosts

        return jsonify(body), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading fleet health.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read fleet health.")
        return error_response("Unable to retrieve fleet health.", 500)

# ===============================
# Sessions and Users APIs
#
# Where each user is and why they cannot connect: the broker's assignments joined with the
# sessions the host agents last reported. The actions a helpdesk operator needs, signing a
# user out and messaging a session, run session-control.sh on the host, which checks again
# that it only touches accounts the broker created. A profile reset is only requested here;
# checkout applies it at the user's next new assignment, so the rename can never race a
# sign-in.

BROKER_USERNAME_RE = re.compile(r'^[A-Za-z0-9_]{1,64}$')
SESSION_STATES = (
    'active', 'disconnected', 'released', 'connecting', 'not-connected',
    'cleanup-pending', 'unmanaged', 'unknown',
)
_SESSION_CONTROL_LINE_RE = re.compile(r'^__SESSION_CONTROL_([A-Z_]+)=(.*)$')
_MESSAGE_CONTROL_CHARACTERS_RE = re.compile(r'[\x00-\x08\x0b-\x1f\x7f]')


class HostAgentOutdated(Exception):
    """The host has no session-control.sh, or sudo does not allow it: its agent predates 1.1.0."""


def host_agent_outdated_response(hostname, what):
    return error_response(
        f"{hostname} runs a host agent older than 1.1.0, which cannot {what}. "
        "Update it with deploy/Migrate-LinuxHostReleaseAgent.ps1.", 409
    )


def parse_session_control_output(stdout):
    values = {}
    for line in (stdout or '').splitlines():
        match = _SESSION_CONTROL_LINE_RE.match(line.strip())
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def run_session_control(hostname, arguments, stdin_input=None, timeout=SESSION_CONTROL_TIMEOUT_SECONDS):
    """Run session-control.sh on a host and return what it reported.

    `sudo -n` fails at once, instead of waiting for a password, on a host whose agent has no
    session-control.sh or does not allow it yet; that is raised as HostAgentOutdated.
    """
    command = "sudo -n {script} {arguments}".format(
        script=REMOTE_SESSION_CONTROL_SCRIPT,
        arguments=' '.join(shlex.quote(str(argument)) for argument in arguments),
    )
    result, host_fqdn = run_remote_command(hostname, command, stdin_input=stdin_input, timeout=timeout)
    values = parse_session_control_output(result.stdout)

    if not values and result.returncode != 0:
        stderr = (result.stderr or '').strip()
        if any(line.strip().startswith('sudo:') for line in stderr.splitlines()):
            raise HostAgentOutdated(hostname)
        logger.error("session-control.sh %s failed on %s (exit %s): %s",
                     arguments[0] if arguments else '', host_fqdn, result.returncode, stderr)

    return values, result.returncode


def normalize_session_message(value):
    """(message, problem) for a message an operator wants shown in sessions."""
    if not isinstance(value, str):
        return None, "Provide the message to send."
    text = _MESSAGE_CONTROL_CHARACTERS_RE.sub('', value.replace('\r\n', '\n').replace('\t', ' ')).strip()
    if not text:
        return None, "Provide the message to send."
    if len(text) > SESSION_MESSAGE_MAX_CHARS:
        return None, f"The message must be at most {SESSION_MESSAGE_MAX_CHARS} characters."
    return text, None


def _epoch_to_utc(value):
    if not isinstance(value, int) or value <= 0:
        return None
    try:
        return datetime.fromtimestamp(value, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except (OverflowError, OSError, ValueError):
        return None


def session_state(row, stale_after):
    """What an operator should read from one row of GetSessions."""
    age = row.get('HeartbeatAgeSeconds')
    fresh = age is not None and age <= stale_after
    reported = row.get('SessionState')

    if row.get('CleanupPending'):
        return 'cleanup-pending'
    if not row.get('BrokerTracked'):
        return 'unmanaged' if fresh else 'unknown'
    if reported in ('active', 'disconnected') and fresh:
        return reported
    if row.get('VmStatus') == 'Released':
        return 'released'
    if not fresh:
        return 'unknown'
    last_checkout = row.get('LastCheckoutAgeSeconds')
    if last_checkout is not None and last_checkout < SESSION_CONNECTING_SECONDS:
        return 'connecting'
    return 'not-connected'


def session_item(row):
    stale_after = heartbeat_stale_after(row.get('ReconcileIntervalSeconds'))
    age = row.get('HeartbeatAgeSeconds')
    grace = row.get('GraceRemainingSeconds')
    return serialize_for_json({
        'Hostname': row.get('Hostname'),
        'VMID': row.get('VMID'),
        'Username': row.get('Username'),
        'AvdHost': row.get('AvdHost'),
        'State': session_state(row, stale_after),
        'VmStatus': row.get('VmStatus'),
        'PowerState': row.get('PowerState'),
        'NetworkStatus': row.get('NetworkStatus'),
        'DrainRequested': bool(row.get('DrainRequested')),
        'HasAssignment': bool(row.get('HasAssignment')),
        'CleanupPending': bool(row.get('CleanupPending')),
        'ReportedState': row.get('SessionState'),
        'SessionStartUtc': _epoch_to_utc(row.get('SessionStartEpoch')),
        'DisconnectedForSeconds': row.get('DisconnectedForSeconds'),
        'IdleSeconds': row.get('IdleSeconds'),
        'AssignedForSeconds': row.get('AssignedForSeconds'),
        'LastCheckoutAgeSeconds': row.get('LastCheckoutAgeSeconds'),
        'GraceRemainingSeconds': max(0, grace) if isinstance(grace, int) else None,
        'GracePeriodSeconds': row.get('GracePeriodSeconds'),
        'HeartbeatAgeSeconds': age,
        'HeartbeatFresh': age is not None and age <= stale_after,
    })


def fetch_sessions():
    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetSessions")
            rows = cursor.fetchall() or []
    return [session_item(row) for row in rows]


def summarize_sessions(sessions):
    summary = {'Total': len(sessions)}
    summary.update({state: 0 for state in SESSION_STATES})
    for session in sessions:
        summary[session['State']] = summary.get(session['State'], 0) + 1
    return summary


@app.route('/api/sessions', methods=['GET'])
@token_required(READ_ROLES)
def get_sessions():
    """Every assignment and reported session. ?q= matches user or host; ?state= one state."""
    try:
        query = (request.args.get('q') or '').strip().lower()
        state = (request.args.get('state') or '').strip().lower() or None
        if state and state not in SESSION_STATES:
            return error_response(f"state must be one of: {', '.join(SESSION_STATES)}.", 400)

        sessions = fetch_sessions()
        summary = summarize_sessions(sessions)
        if query:
            sessions = [
                session for session in sessions
                if query in str(session.get('Username') or '').lower() or query in str(session.get('Hostname') or '').lower()
            ]
        if state:
            sessions = [session for session in sessions if session['State'] == state]

        return jsonify({'Sessions': sessions, 'Summary': summary}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading sessions.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read sessions.")
        return error_response("Unable to retrieve sessions.", 500)


@app.route('/api/users', methods=['GET'])
@token_required(READ_ROLES)
def search_users():
    """Broker users whose name contains ?q=, exact and prefix matches first."""
    try:
        query = re.sub(r'[^A-Za-z0-9_]', '', request.args.get('q') or '')[:64] or None
        limit = coerce_optional_int(request.args.get('limit'), default=25, minimum=1, maximum=USER_SEARCH_MAX_RESULTS)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC SearchUsers @Query = %s, @Limit = %s", (query, limit))
                rows = cursor.fetchall() or []

        return jsonify({'Users': serialize_for_json(rows), 'Query': query}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while searching users.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to search users.")
        return error_response("Unable to search users.", 500)


def user_audit_entries(username, limit=20):
    """Recent audit entries about one user. The reader matches part of a target, so exact
    matches are kept here."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC GetAuditLogPaged @TargetType = %s, @TargetId = %s, @Offset = 0, @PageSize = %s",
                    ('user', username, limit * 2)
                )
                rows = cursor.fetchall() or []
    except DatabaseUnavailable:
        raise
    except Exception:
        logger.exception("Could not read the audit entries for %s.", username)
        return []
    return [_audit_item(row) for row in rows if str(row.get('TargetId') or '').lower() == username.lower()][:limit]


@app.route('/api/users/<username>', methods=['GET'])
@token_required(READ_ROLES)
def get_user_details(username):
    """One user: where they are now, their sessions, the hosts they had, and recent actions."""
    try:
        if not BROKER_USERNAME_RE.match(username or ''):
            return error_response("The username is not valid.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetUserDetails @Username = %s", (username,))
                details = cursor.fetchone()

        if not details:
            return error_response(f"The broker has no user named {username}.", 404)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetUserHostHistory @Username = %s", (username,))
                history = cursor.fetchall() or []

        sessions = [session for session in fetch_sessions() if str(session.get('Username') or '').lower() == username.lower()]
        requested_at = details.get('ProfileResetRequestedAtUtc')

        return jsonify(serialize_for_json({
            'Username': details.get('Username'),
            'Uid': details.get('Uid'),
            'FirstProvisionedDate': details.get('FirstProvisionedDate'),
            'ProfileReset': {
                'RequestedAtUtc': requested_at,
                'RequestedBy': details.get('ProfileResetRequestedBy'),
            } if requested_at else None,
            'Assignments': _json_column(details.get('AssignmentsJson'), list) or [],
            'Sessions': sessions,
            'HostHistory': history,
            'RecentActivity': user_audit_entries(username),
        })), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading user %s.", username)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read user %s.", username)
        return error_response("Unable to retrieve the user.", 500)


def lookup_vm_by_hostname(hostname):
    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetVmByHostname @Hostname = %s", (hostname,))
            return cursor.fetchone()


def reported_session_users(hostname):
    """The users the host's latest heartbeat reports signed in, when that heartbeat is fresh."""
    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetHostHealth @Hostname = %s", (hostname,))
            row = cursor.fetchone() or {}

    age = row.get('HeartbeatAgeSeconds')
    if age is None or age > heartbeat_stale_after(row.get('ReconcileIntervalSeconds')):
        return set()
    return {
        str(session.get('username')).lower()
        for session in (_json_column(row.get('SessionsJson'), list) or [])
        if isinstance(session, dict) and session.get('username')
    }


def resolve_session_target(hostname, username):
    """(vm, error response) for an action on one user's session on one host.

    The host must be registered, and the user must be one the broker has on it (assigned or
    waiting for cleanup) or one the host's fresh heartbeat reports there.
    """
    if not HEARTBEAT_HOSTNAME_RE.match(hostname or ''):
        return None, error_response("The hostname is not valid.", 400)
    if not BROKER_USERNAME_RE.match(username or ''):
        return None, error_response("The username is not valid.", 400)

    vm = lookup_vm_by_hostname(hostname)
    if not vm:
        return None, error_response(f"No VM found with Hostname {hostname}.", 404)

    g.audit_detail = {'hostname': vm.get('Hostname')}
    name = username.lower()
    bound = (
        str(vm.get('Username') or '').lower() == name
        or (vm.get('CleanupPending') and str(vm.get('CleanupUsername') or '').lower() == name)
        or name in reported_session_users(vm.get('Hostname'))
    )
    if not bound:
        return None, error_response(f"The broker has no session for {username} on {vm.get('Hostname')}.", 409)
    if vm.get('PowerState') != 'On':
        return None, error_response(f"{vm.get('Hostname')} is powered off.", 409)
    return vm, None


def release_after_signout(vm, username):
    """Mark the assignment released, as the agent would, so grace starts without it."""
    if str(vm.get('Username') or '').lower() != username.lower() or vm.get('VmStatus') != 'CheckedOut':
        return False
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC ReleaseVm @Hostname = %s, @LeaseId = %s, @Username = %s",
                    (vm.get('Hostname'), normalize_lease_id(vm.get('LeaseId')), vm.get('Username'))
                )
                row = cursor.fetchone() or {}
            conn.commit()
        return (row.get('ReleaseStatus') or '').strip() == 'Released'
    except DatabaseUnavailable:
        raise
    except Exception:
        logger.exception("Could not release %s after signing %s out.", vm.get('Hostname'), username)
        return False


def return_after_signout(vm, username):
    """End the assignment that sign-out left in grace. Returns the cleanup outcome, or None."""
    lease_id = normalize_lease_id(vm.get('LeaseId'))
    if str(vm.get('Username') or '').lower() != username.lower() or not lease_id:
        return None

    with db_connection() as conn:
        with conn.cursor(as_dict=True) as cursor:
            # The lease must still match, so an assignment made since the lookup is untouched.
            cursor.execute("EXEC ReturnVm @VMID = %s, @ExpectedLeaseId = %s", (vm.get('VMID'), lease_id))
            returned = cursor.fetchone()
        conn.commit()

    if not returned or is_procedure_error(returned):
        return None
    return clean_up_returned_user(
        vm.get('VMID'),
        returned.get('Hostname') or vm.get('Hostname'),
        returned.get('ReturnedUsername') or vm.get('Username'),
        returned.get('ReturnedLeaseId') or lease_id,
        timeout=60,
    )


@app.route('/api/sessions/<hostname>/<username>/signout', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('session.signout', target_type='user', target_param='username')
def sign_out_session(hostname, username):
    """End a user's desktop on a host, then release the host. returnHost also ends the assignment."""
    try:
        body = request.get_json(silent=True)
        return_host = isinstance(body, dict) and body.get('returnHost') is True

        vm, problem = resolve_session_target(hostname, username)
        if problem:
            return problem
        hostname = vm.get('Hostname')
        g.audit_detail = {'hostname': hostname, 'returnHost': return_host}

        try:
            values, _ = run_session_control(hostname, ['signout', username])
        except HostAgentOutdated:
            return host_agent_outdated_response(hostname, 'sign users out')

        result = values.get('RESULT')
        g.audit_detail['result'] = result
        if result == 'refused':
            return error_response(f"{hostname} refused to sign out {username}: it is not an account the broker created.", 409)
        if result not in ('signed-out', 'no-session'):
            return error_response(f"Could not sign {username} out of {hostname}. Try again, or restart the host.", 502)

        released = release_after_signout(vm, username)
        cleanup = return_after_signout(vm, username) if return_host else None
        g.audit_detail.update({'released': released, 'cleanupResult': cleanup})

        if cleanup in (CLEANUP_COMPLETED, CLEANUP_NOT_REQUIRED):
            message = f"Signed {username} out of {hostname} and returned the host."
        elif cleanup:
            message = f"Signed {username} out of {hostname}. The host was returned; its cleanup is retried automatically."
        elif result == 'no-session':
            message = f"{username} had no session left on {hostname}."
        else:
            message = f"Signed {username} out of {hostname}. They can reconnect within the grace period."

        return jsonify({
            'Hostname': hostname,
            'Username': username,
            'Result': 'SignedOut' if result == 'signed-out' else 'NoSession',
            'Released': released,
            'Returned': cleanup is not None,
            'CleanupResult': cleanup,
            'message': message,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while signing %s out of %s.", username, hostname)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to sign %s out of %s.", username, hostname)
        return error_response("Unable to sign the user out.", 500)


@app.route('/api/sessions/<hostname>/<username>/message', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('session.message', target_type='user', target_param='username')
def message_session(hostname, username):
    """Show a message in a user's sessions on a host."""
    try:
        body = request.get_json(silent=True)
        message, problem = normalize_session_message(body.get('message') if isinstance(body, dict) else None)
        if problem:
            return error_response(problem, 400)

        vm, problem = resolve_session_target(hostname, username)
        if problem:
            return problem
        hostname = vm.get('Hostname')
        g.audit_detail = {'hostname': hostname, 'message': message[:SESSION_AUDIT_MESSAGE_CHARS]}

        try:
            values, _ = run_session_control(hostname, ['message', username], stdin_input=message)
        except HostAgentOutdated:
            return host_agent_outdated_response(hostname, 'show messages')

        result = values.get('RESULT')
        delivered = coerce_optional_int(values.get('DELIVERED'), default=0, minimum=0)
        sessions = coerce_optional_int(values.get('SESSIONS'), default=0, minimum=0)
        g.audit_detail.update({'result': result, 'delivered': delivered})

        if result == 'refused':
            return error_response(f"{hostname} refused to message {username}: it is not an account the broker created.", 409)
        if result not in ('delivered', 'no-session'):
            return error_response(f"Could not send the message to {hostname}.", 502)

        if result == 'no-session' or not sessions:
            text = f"{username} has no session on {hostname} to show the message in."
        elif delivered < sessions:
            text = f"Sent to {delivered} of {username}'s {sessions} sessions on {hostname}."
        else:
            text = f"Sent to {username} on {hostname}."

        return jsonify({
            'Hostname': hostname,
            'Username': username,
            'Sessions': sessions,
            'Delivered': delivered,
            'message': text,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while messaging %s on %s.", username, hostname)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to message %s on %s.", username, hostname)
        return error_response("Unable to send the message.", 500)


BROADCAST_DESKTOP_STATES = ('active', 'disconnected', 'unmanaged')


def broadcast_targets(vms, sessions, requested):
    """(hostnames to message, requested names that are not registered).

    Without a list, every host someone is using: an assignment or a desktop its heartbeat
    reports. With one, those hosts, whatever the broker knows about their sessions. Only
    powered-on, reachable hosts are messaged either way.
    """
    reachable = {
        str(vm.get('Hostname')).lower(): vm.get('Hostname')
        for vm in vms
        if vm.get('Hostname') and vm.get('PowerState') == 'On' and vm.get('NetworkStatus') == 'Reachable'
    }
    registered = {str(vm.get('Hostname')).lower() for vm in vms if vm.get('Hostname')}

    if requested is not None:
        wanted = {name.lower() for name in requested}
        unknown = sorted(name for name in requested if name.lower() not in registered)
        return sorted((reachable[name] for name in wanted if name in reachable), key=str.lower), unknown

    in_use = {
        str(session.get('Hostname')).lower()
        for session in sessions
        if session.get('HasAssignment') or session.get('State') in BROADCAST_DESKTOP_STATES
    }
    return sorted((reachable[name] for name in in_use if name in reachable), key=str.lower), []


@app.route('/api/sessions/broadcast', methods=['POST'])
@token_required(OPERATE_ROLES)
@audited('session.broadcast', target_type='fleet')
def broadcast_message():
    """Show a message in every session, or in every session on the named hosts."""
    try:
        body = request.get_json(silent=True)
        body = body if isinstance(body, dict) else {}

        message, problem = normalize_session_message(body.get('message'))
        if problem:
            return error_response(problem, 400)

        requested = body.get('hostnames')
        if requested is not None:
            if (not isinstance(requested, list) or len(requested) > BROADCAST_MAX_HOSTNAMES
                    or not all(isinstance(name, str) and HEARTBEAT_HOSTNAME_RE.match(name) for name in requested)):
                return error_response(f"hostnames must be a list of at most {BROADCAST_MAX_HOSTNAMES} hostnames.", 400)
            if not requested:
                return error_response("Name at least one host, or leave hostnames out to message every session.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                vms = cursor.fetchall() or []
        sessions = fetch_sessions() if requested is None else []

        hostnames, unknown = broadcast_targets(vms, sessions, requested)
        skipped = []
        if requested is not None:
            chosen = {name.lower() for name in hostnames}
            missing = {name.lower() for name in unknown}
            skipped = sorted({name for name in requested if name.lower() not in chosen and name.lower() not in missing}, key=str.lower)
        deadline = time.monotonic() + BROADCAST_DEADLINE_SECONDS

        def deliver(hostname):
            if time.monotonic() >= deadline:
                return hostname, None
            try:
                values, _ = run_session_control(
                    hostname, ['message-all'], stdin_input=message, timeout=BROADCAST_HOST_TIMEOUT_SECONDS
                )
            except HostAgentOutdated:
                return hostname, {'Result': 'AgentOutdated'}
            except Exception:
                logger.exception("Could not deliver the broadcast to %s.", hostname)
                return hostname, {'Result': 'Failed'}

            result = values.get('RESULT')
            return hostname, {
                'Result': {'delivered': 'Delivered', 'no-session': 'NoSession'}.get(result, 'Failed'),
                'Sessions': coerce_optional_int(values.get('SESSIONS'), default=0, minimum=0),
                'Delivered': coerce_optional_int(values.get('DELIVERED'), default=0, minimum=0),
            }

        outcomes = []
        if hostnames:
            with ThreadPoolExecutor(max_workers=min(BROADCAST_CONCURRENCY, len(hostnames))) as pool:
                outcomes = list(pool.map(deliver, hostnames))

        results = []
        not_attempted = []
        for hostname, outcome in outcomes:
            if outcome is None:
                not_attempted.append(hostname)
                continue
            results.append({'Hostname': hostname, 'Sessions': 0, 'Delivered': 0, **outcome})

        delivered = sum(entry['Delivered'] for entry in results)
        failed = [entry['Hostname'] for entry in results if entry['Result'] in ('Failed', 'AgentOutdated')]
        g.audit_detail = {
            'message': message[:SESSION_AUDIT_MESSAGE_CHARS],
            'targetCount': len(hostnames),
            'delivered': delivered,
            'hostsFailed': len(failed),
            'notAttempted': len(not_attempted),
        }
        if requested is not None and len(requested) <= 10:
            g.audit_detail['hostnames'] = sorted(requested, key=str.lower)

        if not hostnames:
            summary = ("None of those hosts is powered on and reachable, so nothing was sent."
                       if requested is not None else
                       "No powered-on, reachable host has anyone on it, so nothing was sent.")
        else:
            summary = f"Shown in {delivered} session(s) on {len(hostnames) - len(failed) - len(not_attempted)} of {len(hostnames)} host(s)."
            if failed:
                summary += f" Not delivered to {', '.join(failed[:5])}{' and others' if len(failed) > 5 else ''}."
            if not_attempted:
                summary += f" {len(not_attempted)} host(s) were not reached before the time limit."
            if skipped:
                summary += f" Skipped {len(skipped)} host(s) that are off or unreachable."

        return jsonify({
            'TargetCount': len(hostnames),
            'Delivered': delivered,
            'Results': results,
            'NotAttempted': not_attempted,
            'UnknownHostnames': unknown,
            'SkippedHostnames': skipped,
            'message': summary,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while broadcasting a message.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to broadcast a message.")
        return error_response("Unable to send the message.", 500)


@app.route('/api/users/<username>/reset-profile', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('user.reset_profile_requested', target_type='user', target_param='username')
def request_profile_reset(username):
    """Ask for a fresh profile at the user's next new assignment. The old one is kept."""
    try:
        if not BROKER_USERNAME_RE.match(username or ''):
            return error_response("The username is not valid.", 400)

        body = request.get_json(silent=True)
        body = body if isinstance(body, dict) else {}
        if str(body.get('confirm') or '').strip().lower() != username.lower():
            return jsonify({
                'error': f"Send the username as confirm to reset {username}'s profile.",
                'requiresConfirmation': True,
                'Username': username,
            }), 409

        _, requested_by, _ = audit_actor()
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC RequestProfileReset @Username = %s, @RequestedBy = %s",
                    (username, requested_by)
                )
                row = cursor.fetchone() or {}
            conn.commit()

        if row.get('Result') != 'Requested':
            return error_response(f"The broker has no user named {username}.", 404)

        assigned = bool(row.get('CurrentlyAssigned'))
        g.audit_detail = {'currentlyAssigned': assigned}
        message = (
            f"{username} gets a fresh profile at their next sign-in after the current session ends. "
            "The current profile is kept, renamed."
            if assigned else
            f"{username} gets a fresh profile at their next sign-in. The current profile is kept, renamed."
        )
        return jsonify(serialize_for_json({
            'Username': row.get('Username'),
            'RequestedAtUtc': row.get('ProfileResetRequestedAtUtc'),
            'RequestedBy': row.get('ProfileResetRequestedBy'),
            'CurrentlyAssigned': assigned,
            'message': message,
        })), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while requesting a profile reset for %s.", username)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to request a profile reset for %s.", username)
        return error_response("Unable to request the profile reset.", 500)


@app.route('/api/users/<username>/reset-profile/cancel', methods=['POST'])
@token_required(ADMIN_ROLES)
@audited('user.reset_profile_cancelled', target_type='user', target_param='username')
def cancel_profile_reset(username):
    try:
        if not BROKER_USERNAME_RE.match(username or ''):
            return error_response("The username is not valid.", 400)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC CancelProfileReset @Username = %s", (username,))
                row = cursor.fetchone() or {}
            conn.commit()

        result = row.get('Result')
        g.audit_detail = {'result': result}
        if result == 'NotFound':
            return error_response(f"The broker has no user named {username}.", 404)
        if result == 'NotPending':
            return jsonify({'Username': username, 'Result': result, 'message': f"{username} had no profile reset pending."}), 200
        return jsonify({'Username': username, 'Result': result, 'message': f"Cancelled the profile reset for {username}."}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while cancelling a profile reset for %s.", username)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to cancel a profile reset for %s.", username)
        return error_response("Unable to cancel the profile reset.", 500)


def apply_pending_profile_reset(vmid, hostname, username):
    """Apply a requested profile reset during a new checkout, before the home is mounted.

    Never fails the checkout: if the reset cannot be applied now, the user signs in with the
    existing profile and the reset stays pending for a later checkout. Returns the outcome.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC BeginProfileReset @Username = %s, @VMID = %s", (username, vmid))
                row = cursor.fetchone() or {}

        readiness = row.get('Result')
        if readiness != 'Ready':
            if readiness == 'InUseElsewhere':
                logger.info("Left the profile reset for %s pending: the profile may be in use on another host.", username)
            return readiness

        if not NFS_SHARE:
            logger.error("Cannot reset the profile of %s: NFS_SHARE is not configured.", username)
            return 'NotConfigured'

        try:
            values, _ = run_session_control(
                hostname, ['reset-profile', NFS_SHARE, username], timeout=PROFILE_RESET_TIMEOUT_SECONDS
            )
        except HostAgentOutdated:
            logger.warning("Left the profile reset for %s pending: %s runs a host agent older than 1.1.0.", username, hostname)
            audit('user.reset_profile_applied', 'user', username, AUDIT_FAILURE, {
                'hostname': hostname, 'error': 'The host agent is older than 1.1.0.',
            })
            return 'AgentOutdated'

        outcome = values.get('RESULT')
        if outcome not in ('profile-reset', 'profile-missing'):
            logger.error("The profile reset for %s failed on %s (%s); it stays pending.", username, hostname, outcome)
            audit('user.reset_profile_applied', 'user', username, AUDIT_FAILURE, {
                'hostname': hostname, 'result': outcome or 'error',
            })
            return outcome or 'Failed'

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC CompleteProfileReset @Username = %s", (username,))
                cursor.fetchone()
            conn.commit()

        audit('user.reset_profile_applied', 'user', username, AUDIT_SUCCESS, {
            'hostname': hostname, 'result': outcome, 'renamedTo': values.get('RENAMED_TO'),
        })
        return outcome
    except Exception:
        logger.exception("Could not apply the profile reset for %s on %s; it stays pending.", username, hostname)
        return 'Failed'

# ===============================
# Audit APIs


class AuditFilterError(Exception):
    """An audit log filter the caller must correct. The message names the field."""

    def __init__(self, client_message):
        super().__init__(client_message)
        self.client_message = client_message


_AUDIT_TIME_FORMATS = ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M')


def parse_audit_time(value, field, end_of_day=False):
    """A UTC date (YYYY-MM-DD) or ISO-8601 UTC time, as a naive UTC datetime.

    A bare date for the end of a range means the whole of that day, so it becomes the next
    midnight: the procedure's upper bound is exclusive.
    """
    text = str(value or '').strip()
    if not text:
        return None
    if text[-1:] in ('Z', 'z'):
        text = text[:-1]

    try:
        day = datetime.strptime(text, '%Y-%m-%d')
        return day + timedelta(days=1) if end_of_day else day
    except ValueError:
        pass

    for time_format in _AUDIT_TIME_FORMATS:
        try:
            return datetime.strptime(text, time_format)
        except ValueError:
            continue

    raise AuditFilterError(f"{field} must be a date (YYYY-MM-DD) or an ISO-8601 UTC time.")


def _audit_filter(value, max_length):
    text = str(value or '').strip()
    return text[:max_length] or None


def _audit_item(row):
    item = {key: value for key, value in row.items() if key not in ('TotalCount', 'DetailJson')}
    item['Detail'] = _json_column(row.get('DetailJson'), (dict, list))
    return item


@app.route('/api/audit', methods=['GET'])
@token_required(READ_ROLES)
def get_audit_log():
    """Audit entries, newest first, paged and filtered like the history endpoints."""
    try:
        args = request.args
        try:
            start = parse_audit_time(args.get('from'), 'from')
            end = parse_audit_time(args.get('to'), 'to', end_of_day=True)
        except AuditFilterError as e:
            return error_response(e.client_message, 400)

        outcome = _audit_filter(args.get('outcome'), 16)
        if outcome and outcome.lower() not in AUDIT_OUTCOMES:
            return error_response("outcome must be success, failure or denied.", 400)

        page = coerce_optional_int(args.get('page'), default=1, minimum=1)
        per_page = coerce_optional_int(args.get('per_page'), default=DEFAULT_PAGE_SIZE, minimum=1, maximum=AUDIT_MAX_PAGE_SIZE)
        offset = (page - 1) * per_page

        filters = (
            start,
            end,
            _audit_filter(args.get('actor'), 256),
            _audit_filter(args.get('action'), 64),
            _audit_filter(args.get('targetType'), 32),
            _audit_filter(args.get('target'), 256),
            outcome.lower() if outcome else None,
        )
        statement = (
            "EXEC GetAuditLogPaged @From = %s, @To = %s, @Actor = %s, @Action = %s, @TargetType = %s, "
            "@TargetId = %s, @Outcome = %s, @Offset = %s, @PageSize = %s"
        )

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(statement, filters + (offset, per_page))
                rows = cursor.fetchall() or []

                # As in run_history_query: an out-of-range page must still report the total.
                if not rows and offset > 0:
                    cursor.execute(statement, filters + (0, 1))
                    probe = cursor.fetchall() or []
                    total = int(probe[0].get('TotalCount') or 0) if probe else 0
                else:
                    total = int(rows[0].get('TotalCount') or 0) if rows else 0

        return jsonify(serialize_for_json({
            'items': [_audit_item(row) for row in rows],
            'page': page,
            'per_page': per_page,
            'total': total,
            'total_pages': (total + per_page - 1) // per_page if per_page else 0,
        })), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while reading the audit log.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to read the audit log.")
        return error_response("Unable to retrieve the audit log.", 500)


@app.route('/api/audit/purge', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
def purge_audit_log():
    """Remove audit entries older than AUDIT_RETENTION_DAYS. The scheduled task runs it daily.

    Not decorated with @audited: the purge is recorded below with what it removed, whoever
    called it.
    """
    try:
        deleted = 0
        more_remaining = True
        batches = 0
        deadline = time.monotonic() + AUDIT_PURGE_TIME_BUDGET_SECONDS

        # pymssql keeps one transaction open until commit, so each call deletes a single batch
        # and commits it; the locks it holds never outlast one batch.
        try:
            with db_connection() as conn:
                while more_remaining and batches < AUDIT_PURGE_MAX_BATCHES and time.monotonic() < deadline:
                    with conn.cursor(as_dict=True) as cursor:
                        cursor.execute(
                            "EXEC PurgeAuditLog @RetentionDays = %s, @BatchSize = %s, @MaxBatches = 1",
                            (AUDIT_RETENTION_DAYS, AUDIT_PURGE_BATCH_SIZE)
                        )
                        row = cursor.fetchone() or {}
                    conn.commit()

                    deleted += int(row.get('Deleted') or 0)
                    more_remaining = bool(row.get('MoreRemaining'))
                    batches += 1
        except Exception:
            # The batches already committed stay deleted, so record them.
            if deleted:
                audit('audit.purge', 'audit', None, AUDIT_FAILURE, {
                    'deleted': deleted,
                    'retentionDays': AUDIT_RETENTION_DAYS,
                    'moreRemaining': True,
                })
            raise

        audit('audit.purge', 'audit', None, AUDIT_SUCCESS, {
            'deleted': deleted,
            'retentionDays': AUDIT_RETENTION_DAYS,
            'moreRemaining': more_remaining,
        })

        return jsonify({
            'Deleted': deleted,
            'RetentionDays': AUDIT_RETENTION_DAYS,
            'MoreRemaining': more_remaining,
        }), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while purging the audit log.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to purge the audit log.")
        return error_response("Unable to purge the audit log.", 500)

# ===============================
# Error Handlers

# Werkzeug answers routing failures, such as a non-integer VMID, with an HTML page.
# Keep them in the same JSON envelope as every other API error.
@app.errorhandler(404)
def handle_not_found(e):
    return error_response("The requested resource was not found.", 404)

@app.errorhandler(405)
def handle_method_not_allowed(e):
    response, status = error_response("The method is not allowed for the requested URL.", 405)
    valid_methods = getattr(e, 'valid_methods', None)
    if valid_methods:
        response.headers['Allow'] = ', '.join(valid_methods)
    return response, status

# ===============================
# Main

password_refresh_thread = threading.Thread(target=refresh_db_password, args=(3600,), daemon=True)
password_refresh_thread.start()

if __name__ == '__main__':
    # Debug mode stays off unless FLASK_DEBUG=1 is set. The container runs gunicorn,
    # so this block is only used for local runs.
    app.run()
