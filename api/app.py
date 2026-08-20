import os
import json
import subprocess
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

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.api')

from flask import Flask, jsonify, request
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
app.config['VERSION'] = '0.159'

# Backs is_member_of_group_cached, which keeps token validation off the Graph API on
# every request.
cache = Cache(app, config={'CACHE_TYPE': 'simple'})

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

def get_access_token(tenant_id, client_id, client_secret):
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
    
    response = requests.post(url, headers=headers, data=data)
    if response.status_code == 200:
        return response.json().get("access_token")
    else:
        response.raise_for_status()

def get_or_create_uid(username):
    try:
        with db_connection() as conn:
            cursor = conn.cursor(as_dict=True)

            # Check if user already exists
            cursor.execute("SELECT uid FROM VmUsers WHERE username = %s", (username,))
            result = cursor.fetchone()
            if result:
                return result['uid']

            # Assign a new UID starting from 2000
            cursor.execute("SELECT MAX(uid) AS max_uid FROM VmUsers")
            max_uid = cursor.fetchone()['max_uid'] or 1999
            new_uid = max_uid + 1

            # Insert new user
            cursor.execute("INSERT INTO VmUsers (username, uid) VALUES (%s, %s)", (username, new_uid))
            conn.commit()

        return new_uid
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


class GroupCheckUnavailable(Exception):
    """Group membership could not be determined (Graph unreachable, throttled, or
    no token).

    Distinct from "the principal is not a member" so a transient Graph failure is
    never cached as an authorization denial.
    """


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

def create_or_update_remote_user(hostname: str, username: str, password: str, lease_id: str) -> bool:
    normalized_lease_id = normalize_lease_id(lease_id)
    if not normalized_lease_id:
        logger.error("Cannot provision remote user %s on %s without a valid LeaseId.", username, hostname)
        return False

    try:
        uid = get_or_create_uid(username)
        if not isinstance(uid, int):
            logger.error("Cannot provision remote user %s on %s without a uid.", username, hostname)
            return False

        create_user_command = "sudo {script} {nfs_share} {uid} {username} {lease_id}".format(
            script=REMOTE_CREATE_USER_SCRIPT,
            nfs_share=shlex.quote(NFS_SHARE or ''),
            uid=shlex.quote(str(uid)),
            username=shlex.quote(username),
            lease_id=shlex.quote(normalized_lease_id)
        )

        result, host_fqdn = run_remote_command(hostname, create_user_command)
        if result.returncode != 0:
            logger.error("Failed to create or update user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return False

        # Sent over stdin so the credential never appears in the remote process list or auth logs.
        result, host_fqdn = run_remote_command(hostname, 'sudo chpasswd', stdin_input=f"{username}:{password}\n")
        if result.returncode != 0:
            logger.error("Failed to set password for user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return False

        return True
    except Exception as e:
        logger.error("Error creating or updating user '%s' on VM '%s': %s", username, hostname, e)
        return False

def release_vm_assignment(vmid, lease_id) -> bool:
    """Undo a checkout whose Linux-side provisioning failed, so the VM is not stranded."""
    normalized_lease_id = normalize_lease_id(lease_id)

    if not vmid or not normalized_lease_id:
        return False

    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC ReturnVm @VMID = %s, @ExpectedLeaseId = %s",
                    (vmid, normalized_lease_id)
                )
                row = cursor.fetchone()

            conn.commit()

        if not row:
            logger.error("Could not release VMID %s after a failed checkout; the lease no longer matches.", vmid)
            return False

        logger.info("Released VMID %s after a failed checkout.", vmid)
        return True
    except DatabaseUnavailable:
        logger.error("Database connection failed while releasing VMID %s after a failed checkout.", vmid)
        return False
    except Exception:
        logger.exception("Error releasing VMID %s after a failed checkout.", vmid)
        return False

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

    response = requests.post(url, headers=headers, json=body)

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

def delete_remote_user(hostname: str, username: str, lease_id: str = None) -> bool:
    normalized_lease_id = normalize_lease_id(lease_id)

    try:
        quoted_username = shlex.quote(username)
        missing_user_message = shlex.quote(f"User {username} does not exist")
        delete_user_command = f"sudo userdel -r {quoted_username} 2>/dev/null || echo {missing_user_message}"

        if normalized_lease_id:
            clear_lease_command = "sudo {script} clear {username} {lease_id}".format(
                script=REMOTE_MANAGE_LEASE_SCRIPT,
                username=quoted_username,
                lease_id=shlex.quote(normalized_lease_id)
            )

            result, host_fqdn = run_remote_command(hostname, clear_lease_command)
            if result.returncode != 0:
                logger.error("Failed to evaluate lease for user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
                return False

            if '__LEASE_ACTION=cleared__' not in result.stdout:
                logger.info("Skipped deleting user '%s' on VM '%s' because the lease no longer matches.", username, hostname)
                return True
        else:
            clear_lease_command = "sudo {script} clear-any {username} >/dev/null 2>&1 || true".format(
                script=REMOTE_MANAGE_LEASE_SCRIPT,
                username=quoted_username
            )
            delete_user_command = f"{delete_user_command}; {clear_lease_command}"

        result, host_fqdn = run_remote_command(hostname, delete_user_command)

        if result.returncode != 0:
            logger.error("Failed to delete user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return False

        return True
    except Exception as e:
        logger.error("Error deleting user '%s' on VM '%s': %s", username, hostname, e)
        return False

@cache.memoize(timeout=300)
def is_member_of_group_cached(user_oid, group_ids):
    # memoize needs hashable arguments, so the caller passes a tuple.
    return is_member_of_group(user_oid, list(group_ids))
     
def token_required(required_permissions=None, required_group_ids=None):
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
                jwks_uri = f"{AUTHORITY_HOST}/{TENANT_ID}/discovery/v2.0/keys"
                jwks_response = requests.get(jwks_uri)
                if jwks_response.status_code != 200:
                    return jsonify({'message': 'Failed to retrieve JWKS.'}), 500
                jwks = jwks_response.json()
                
                unverified_header = jwt.get_unverified_header(token)
                
                rsa_key = {}
                for key in jwks["keys"]:
                    if key["kid"] == unverified_header["kid"]:
                        rsa_key = {
                            "kty": key["kty"],
                            "kid": key["kid"],
                            "use": key["use"],
                            "n": key["n"],
                            "e": key["e"]
                        }
                        break
                
                if not rsa_key:
                    return jsonify({'message': 'Invalid token: RSA key not found.'}), 401
                
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
                
                has_scope_permission = False
                has_role_permission = False
                
                if 'scp' in payload and required_permissions:
                    token_scopes = payload['scp'].split()
                    if any(scope in token_scopes for scope in required_permissions):
                        has_scope_permission = True
                
                if 'roles' in payload and required_permissions:
                    token_roles = payload['roles']
                    if any(role in token_roles for role in required_permissions):
                        has_role_permission = True
                
                is_in_group = False
                if required_group_ids:
                    # Use the memoized wrapper: this runs on every authenticated
                    # request from the AVD and Linux hosts, and the uncached path was
                    # calling Microsoft Graph each time.
                    try:
                        is_in_group = is_member_of_group_cached(user_oid, tuple(required_group_ids))
                    except GroupCheckUnavailable:
                        # Not cached, and reported as a dependency failure rather than
                        # a denial, so a Graph blip does not look like a permissions
                        # problem to the AVD and Linux host agents.
                        logger.exception("Could not verify group membership for %s.", user_oid)
                        return jsonify({'error': 'Unable to verify group membership. Please retry.'}), 503
                
                if not (has_scope_permission or has_role_permission or is_in_group):
                    logger.error("Access denied: insufficient scope or role permissions or group membership.")
                    return jsonify({'message': 'Access denied: insufficient scope or role permissions or group membership.'}), 403

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
            
            return f(*args, **kwargs)
        return decorated
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

# ===============================
# VM Management APIs

@app.route('/api/vms', methods=['GET'])
@token_required(['access_as_user', 'FullAccess', 'ScheduledTask'])
def get_all_vms():
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                rows = cursor.fetchall()

        return jsonify(serialize_for_json(rows or [])), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while listing VMs.")
        return error_response("Database connection failed.", 500)
    except Exception:
        logger.exception("Failed to list VMs.")
        return error_response("Unable to retrieve virtual machines.", 500)

@app.route('/api/vms/summary', methods=['GET'])
@token_required(['access_as_user', 'FullAccess', 'ScheduledTask'])
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
@token_required(['AvdHost', 'access_as_user', 'FullAccess'], required_group_ids=[AVD_HOST_GROUP_ID])
def checkout_vm():
    try:
        req_body = request.get_json()

        username = req_body.get('username')
        avdhost = req_body.get('avdhost')

        if not username or not avdhost:
            return error_response("Please provide 'username' and 'avdhost' in the request body.", 400)

        username = re.sub(r'[^a-zA-Z0-9_]', '', username)
        user_password = generate_secure_password()

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.callproc('CheckoutVm', (username, avdhost))
                rows = cursor.fetchall()
                conn.commit()

        if not rows or 'Message' in rows[0]:
            return error_response("No available VM found. Please try again.", 409)

        checked_out_vm = rows[0]
        vm_hostname = checked_out_vm.get('Hostname')
        lease_id = normalize_lease_id(checked_out_vm.get('LeaseId'))

        if not vm_hostname or not lease_id:
            return error_response("No hostname or LeaseId found for the checked-out VM.", 500)

        if not create_or_update_remote_user(vm_hostname, username, user_password, lease_id):
            release_vm_assignment(checked_out_vm.get("VMID"), lease_id)
            return error_response(f"Failed to create or update user '{username}' on VM '{vm_hostname}'.", 500)
        
        groups_to_add = ["tsusers", "appusers"]

        if not remote_group_exists(vm_hostname, "tsusers"):
            if not create_remote_group(vm_hostname, "tsusers"):
                return error_response(f"Failed to create group 'tsusers' on VM '{vm_hostname}'.", 500)

        if not remote_group_exists(vm_hostname, "appusers"):
            if not create_remote_group(vm_hostname, "appusers"):
                return error_response(f"Failed to create group 'appusers' on VM '{vm_hostname}'.", 500)

        for group in groups_to_add:
            if not is_user_in_remote_group(vm_hostname, username, group):
                add_user_to_remote_group(vm_hostname, username, group)

        response_data = {
            "VMID": checked_out_vm.get("VMID"),
            "Hostname": checked_out_vm.get("Hostname"),
            "IPAddress": checked_out_vm.get("IPAddress"),
            "LeaseId": lease_id,
            "password": user_password
        }

        #print(f"================= Response data: {response_data}")    

        return jsonify(serialize_for_json(response_data)), 200

    except json.JSONDecodeError:
        return error_response("Invalid JSON data", 400)

    except DatabaseUnavailable:
        logger.error("Database connection failed while checking out a VM.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to check out a VM.")
        return error_response("Unable to check out a virtual machine.", 500)

@app.route('/api/vms/<vmid>/update-attributes', methods=['POST'])
@token_required(['ScheduledTask', 'access_as_user', 'FullAccess'])
def update_vm_attributes(vmid):
    try:
        req_body = request.get_json()

        powerstate = req_body.get('powerstate')
        networkstatus = req_body.get('networkstatus')
        vmstatus = req_body.get('vmstatus')

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

        return jsonify(row), 200

    except json.JSONDecodeError:
        return jsonify({'error': "Invalid JSON data"}), 400

    except DatabaseUnavailable:
        logger.error("Database connection failed while updating VM %s attributes.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to update VM %s attributes.", vmid)
        return error_response("Unable to update virtual machine attributes.", 500)

@app.route('/api/vms/<vmid>/delete', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def delete_vm(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC DeleteVm @VMID = %s", (vmid,))
                row = cursor.fetchone()

            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} could not be deleted or was not found.", 404)

        return f"VM with VMID {vmid} has been successfully deleted.", 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while deleting VM %s.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to delete VM %s.", vmid)
        return error_response("Unable to delete the virtual machine.", 500)

@app.route('/api/vms/add', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def add_new_vm():
    try:
        req_body = request.get_json()

        hostname = req_body.get('hostname')
        ipaddress = req_body.get('ipaddress')
        powerstate = req_body.get('powerstate')
        networkstatus = req_body.get('networkstatus')
        vmstatus = req_body.get('vmstatus')
        username = req_body.get('username', None)
        avdhost = req_body.get('avdhost', None)
        description = req_body.get('description', None)

        if not (hostname and ipaddress and powerstate and networkstatus and vmstatus):
            return error_response("Please provide 'hostname', 'ipaddress', 'powerstate', 'networkstatus', and 'vmstatus' in the request body.", 400)

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

        return jsonify({"NewVMID": row['NewVMID']}), 201

    except json.JSONDecodeError:
        return error_response("Invalid JSON data", 400)

    except DatabaseUnavailable:
        logger.error("Database connection failed while adding a VM.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to add a VM.")
        return error_response("Unable to add the virtual machine.", 500)

@app.route('/api/vms/<vmid>', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
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

@app.route('/api/vms/<vmid>/return', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def return_vm(vmid):
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC ReturnVm @VMID = %s", (vmid,))
                row = cursor.fetchone()
            conn.commit()

        if not row:
            return error_response(f"VM with VMID {vmid} was not found or is not currently checked out.", 404)

        hostname = row.get('Hostname')
        username = row.get('ReturnedUsername')
        lease_id = row.get('ReturnedLeaseId')

        if hostname and username:
            success = delete_remote_user(hostname, username, lease_id)
            if success:
                logger.info("Successfully deleted user %s from %s during manual return.", username, hostname)
            else:
                logger.error("Failed to delete user %s from %s during manual return.", username, hostname)

        return jsonify(serialize_for_json(row)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while returning VM %s.", vmid)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to return VM %s.", vmid)
        return error_response("Unable to return the virtual machine.", 500)

@app.route('/api/vms/<hostname>/release', methods=['POST'])
@token_required(['LinuxHost', 'access_as_user', 'FullAccess'], required_group_ids=[LINUX_HOST_GROUP_ID])
def release_vm(hostname):
    try:
        req_body = request.get_json(silent=True) or {}
        lease_id_raw = req_body.get('leaseId') or request.args.get('leaseId')
        username = req_body.get('username') or request.args.get('username')
        lease_id = normalize_lease_id(lease_id_raw)

        if lease_id_raw and not lease_id:
            return jsonify({'error': 'Invalid leaseId format.'}), 400

        if username:
            username = re.sub(r'[^a-zA-Z0-9_]', '', username)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC ReleaseVm @Hostname = %s, @LeaseId = %s, @Username = %s",
                    (hostname, lease_id, username)
                )
                row = cursor.fetchone()

            conn.commit()

        if not row:
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

    except DatabaseUnavailable:
        logger.error("Database connection failed while releasing VM with Hostname %s.", hostname)
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to release VM with Hostname %s.", hostname)
        return error_response("Unable to release the virtual machine.", 500)

@app.route('/api/vms/released', methods=['POST'])
@token_required(['ScheduledTask', 'access_as_user', 'FullAccess'])
def return_released_vm_api():
    try:
        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC ReturnReleasedVms")
                rows = cursor.fetchall()
            conn.commit()

        if not rows:
            return "No VMs to return at this time.", 200

        for row in rows:
            hostname = row.get("Hostname")
            username = row.get("ReturnedUsername")
            lease_id = row.get("ReturnedLeaseId")

            if hostname and username:
                success = delete_remote_user(hostname, username, lease_id)
                if success:
                    logger.info("Successfully deleted user %s from %s", username, hostname)
                else:
                    logger.error("Failed to delete user %s from %s", username, hostname)

        return jsonify(serialize_for_json(rows)), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while returning released VMs.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to return released VMs.")
        return error_response("Unable to return released virtual machines.", 500)


@app.route('/api/vms/history', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def get_vm_history():
    return run_history_query(
        proc='GetVmHistory',
        paged_proc='GetVmHistoryPaged',
        label='VM history',
    )

# ===============================
# Scaling APIs

@app.route('/api/scaling/log', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_activity_log():
    return run_history_query(
        proc='GetScalingActivityLog',
        paged_proc='GetScalingActivityLogPaged',
        label='scaling activity log',
    )

@app.route('/api/scaling/trigger', methods=['POST'])
@token_required(['ScheduledTask', 'access_as_user', 'FullAccess'])
def trigger_scaling_logic():
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return error_response("Configuration error: missing Azure subscription or resource group.", 500)

        credential = DefaultAzureCredential()
        compute_client = ComputeManagementClient(credential=credential, subscription_id=VM_SUBSCRIPTION_ID)

        with db_connection() as conn:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC TriggerScalingLogic")
                rows = cursor.fetchall()
            # TriggerScalingLogic updates PowerState on the selected VMs and inserts
            # the activity-log row. pymssql does not autocommit, so without this the
            # database rolled all of it back while the Azure power operations below
            # still went ahead -- leaving Azure and the broker out of step and the
            # scaling activity log permanently empty.
            conn.commit()
        powered_on_vms = []
        powered_off_vms = []

        for row in rows:
            vm_name = row['VMName']
            if row['ActionType'] == 'PowerOn':
                compute_client.virtual_machines.begin_start(VM_RESOURCE_GROUP, vm_name)
                powered_on_vms.append(vm_name)
            elif row['ActionType'] == 'PowerOff':
                compute_client.virtual_machines.begin_power_off(VM_RESOURCE_GROUP, vm_name)
                powered_off_vms.append(vm_name)

        response_payload = {
            'PoweredOnVMs': powered_on_vms,
            'PoweredOffVMs': powered_off_vms
        }

        return jsonify(response_payload), 200

    except DatabaseUnavailable:
        logger.error("Database connection failed while triggering scaling logic.")
        return error_response("Database connection failed.", 500)

    except Exception:
        logger.exception("Failed to trigger scaling logic.")
        return error_response("Unable to trigger scaling logic.", 500)

# ===============================
# Scaling Rules APIs

@app.route('/api/scaling/rules', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
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
@token_required(['access_as_user', 'FullAccess'])
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
@token_required(['access_as_user', 'FullAccess'])
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
@token_required(['access_as_user', 'FullAccess'])
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
@token_required(['access_as_user', 'FullAccess'])
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
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_rules_history():
    return run_history_query(
        proc='GetVMScalingRulesHistory',
        paged_proc='GetVmScalingRulesHistoryPaged',
        label='scaling rules history',
    )

# ===============================
# Linux Host Settings APIs

@app.route('/api/hosts/settings', methods=['GET'])
@token_required(['LinuxHost', 'access_as_user', 'FullAccess', 'ScheduledTask'], required_group_ids=[LINUX_HOST_GROUP_ID])
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
@token_required(['access_as_user', 'FullAccess'])
def update_host_settings():
    try:
        payload = request.get_json(silent=True) or {}
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
@token_required(['access_as_user', 'FullAccess', 'ScheduledTask'])
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
@token_required(['LinuxHost', 'access_as_user', 'FullAccess'], required_group_ids=[LINUX_HOST_GROUP_ID])
def acknowledge_host_settings(hostname):
    """Record the settings version a host has applied, so the portal can show drift."""
    try:
        payload = request.get_json(silent=True) or {}
        raw_version = payload.get('settingsVersion')

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
# Main

password_refresh_thread = threading.Thread(target=refresh_db_password, args=(3600,), daemon=True)
password_refresh_thread.start()

if __name__ == '__main__':
    app.run(debug=True)
