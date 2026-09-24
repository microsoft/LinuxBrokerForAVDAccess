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

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.api')

from flask import Flask, g, jsonify, request
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from functools import wraps
from contextlib import contextmanager
from flask_caching import Cache
from azure.keyvault.secrets import SecretClient
from config import *

# ===============================
# Flask App

app = Flask(__name__)
app.config['VERSION'] = '0.164'

# Backs is_member_of_group_cached, which keeps token validation off the Graph API on
# every request.
cache = Cache(app, config={'CACHE_TYPE': 'simple'})

REMOTE_CREATE_USER_SCRIPT = '/usr/local/bin/create-user.sh'
REMOTE_MANAGE_LEASE_SCRIPT = '/usr/local/bin/manage-lease.sh'
REMOTE_APPLY_SETTINGS_SCRIPT = '/usr/local/bin/apply-host-settings.sh'

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

def complete_vm_cleanup(vmid, lease_id, username) -> bool:
    """Clear CleanupPending once the user is gone, so the VM can be checked out again."""
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC CompleteVmCleanup @VMID = %s, @LeaseId = %s, @Username = %s",
                    (vmid, normalize_lease_id(lease_id), username)
                )
                row = cursor.fetchone()

            conn.commit()

        return bool(row)
    except DatabaseUnavailable:
        logger.error("Database connection failed while completing the cleanup of VMID %s.", vmid)
        return False
    except Exception:
        logger.exception("Error completing the cleanup of VMID %s.", vmid)
        return False

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
                  'PoweredOn', 'PoweredOff', 'Unreachable', 'Ready', 'CleanupPending')
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

        if not vm_hostname or not lease_id:
            return error_response("No hostname or LeaseId found for the checked-out VM.", 500)

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

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while updating VM %s attributes.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to update VM %s attributes.", vmid)
        return error_response("Unable to update virtual machine attributes.", 500)

@app.route('/api/vms/<int:vmid>/network-status', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
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

        if username:
            outcome = clean_up_returned_user(vmid, hostname, username, lease_id, timeout=60)
        else:
            outcome = CLEANUP_COMPLETED if complete_vm_cleanup(vmid, lease_id, None) else CLEANUP_FAILED

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
def delete_vm(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteVm @VMID = %s", (vmid,))
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} could not be deleted or was not found.", 404)

        return jsonify({'message': f"VM with VMID {vmid} has been successfully deleted.", 'VMID': vmid}), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while deleting VM %s.", vmid)
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to delete VM %s.", vmid)
        return error_response("Unable to delete the virtual machine.", 500)

@app.route('/api/vms/add', methods=['POST'])
@token_required(ADMIN_ROLES)
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
        outcome = clean_up_returned_user(vmid, hostname, username, row.get('ReturnedLeaseId'), timeout=60)

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

@app.route('/api/vms/released', methods=['POST'])
@token_required([ROLE_SCHEDULED_TASK, ROLE_ADMIN])
def return_released_vm_api():
    """Return Released VMs whose grace period has expired, and retry pending cleanups.

    A returned VM stays CleanupPending until its user has been removed from the host, so a
    host that cannot be cleaned now is retried on a later run instead of being handed to the
    next user with the previous session still on it. Cleanups run in parallel and stop
    starting new work at the deadline, so one slow host cannot hold up the rest.
    """
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC ReturnReleasedVms")
                rows = cursor.fetchall()
            conn.commit()

        rows = [row for row in (rows or []) if not is_procedure_error(row)]
        if not rows:
            return jsonify([]), 200

        deadline = time.monotonic() + SWEEP_DEADLINE_SECONDS
        with ThreadPoolExecutor(max_workers=min(SWEEP_CONCURRENCY, len(rows))) as pool:
            outcomes = list(pool.map(lambda row: _sweep_cleanup(row, deadline), rows))

        results = []
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

        logger.info(
            "Released VM sweep processed %s row(s): %s.",
            len(results), ', '.join(f"{key}={value}" for key, value in sorted(tally.items()))
        )

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
                except Exception:
                    logger.exception("Azure refused to start %s.", vm_name)
                    revert_power_action(row, 'Off')
                    append_scaling_note(row.get('ActivityID'), f"Starting {vm_name} failed, so it was recorded as off again.")
                    failed.append({'VMName': vm_name, 'Action': 'PowerOn', 'Error': 'The Azure start operation could not be requested.'})
            elif action in ('PowerOff', 'PoweredOff'):
                deallocate = (row.get('StopMode') or 'PowerOff') == 'Deallocate'
                try:
                    if deallocate:
                        compute_client.virtual_machines.begin_deallocate(VM_RESOURCE_GROUP, vm_name)
                        deallocated_vms.append(vm_name)
                    else:
                        compute_client.virtual_machines.begin_power_off(VM_RESOURCE_GROUP, vm_name)
                        powered_off_vms.append(vm_name)
                except Exception:
                    logger.exception("Azure refused to stop %s.", vm_name)
                    revert_power_action(row, 'On')
                    append_scaling_note(row.get('ActivityID'), f"Stopping {vm_name} failed, so it was recorded as running again.")
                    failed.append({
                        'VMName': vm_name,
                        'Action': 'Deallocate' if deallocate else 'PowerOff',
                        'Error': 'The Azure stop operation could not be requested.',
                    })

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

        return jsonify({"NewRuleID": int(new_rule_id)}), 201

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while creating a scaling rule.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to create a scaling rule.")
        return error_response("Unable to create the scaling rule.", 500)

@app.route('/api/scaling/rules/<int:ruleid>/update', methods=['POST'])
@token_required(ADMIN_ROLES)
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
        merged.update(changes)
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
def update_host_settings():
    try:
        payload = request.get_json(silent=True) or {}
        if not isinstance(payload, dict):
            return jsonify({'error': 'Settings payload must be a JSON object.'}), 400

        updated_by = payload.pop('updatedBy', None)

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

        return jsonify(normalize_host_settings(row)), 200

    except DatabaseUnavailable as e:
        logger.error("Database connection failed while updating Linux host settings.")
        return database_unavailable_response(e)

    except Exception:
        logger.exception("Failed to update Linux host settings.")
        return jsonify({'error': 'Unable to update Linux host settings.'}), 500

@app.route('/api/hosts/settings/apply', methods=['POST'])
@token_required(OPERATE_ROLES + [ROLE_SCHEDULED_TASK])
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
