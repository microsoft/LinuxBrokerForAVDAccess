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
from flask_caching import Cache
from azure.keyvault.secrets import SecretClient
from config import *

# ===============================
# Flask App

app = Flask(__name__)
app.config['VERSION'] = '0.158'

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
    conn = get_db_connection()
    if not conn:
        return jsonify({'status': 'unhealthy'}), 503

    try:
        cursor = conn.cursor()
        cursor.execute('SELECT 1')
        cursor.fetchone()
        return jsonify({'status': 'healthy', 'version': app.config['VERSION']}), 200
    except Exception as e:
        logger.error("Health check failed: %s", e)
        return jsonify({'status': 'unhealthy'}), 503
    finally:
        conn.close()

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
        print("Error retrieving password from Key Vault: %s", e)
        db_password = None

def get_db_connection():
    global db_password
    if db_password is None:
        retrieve_db_password_from_key_vault()
        if db_password is None:
            print("Cannot connect to database without a password.")
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
        print("Error connecting to database: %s", e)
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
            print("Failed to write PEM key to file: %s", e)
            raise
    else:
        current_permissions = oct(os.stat(pem_file_path).st_mode & 0o777)
        if int(current_permissions, 8) != required_permissions:
            try:
                os.chmod(pem_file_path, required_permissions)
            except Exception as e:
                print("Failed to update permissions for %s: %s", pem_file_path, e)
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
        conn = get_db_connection()
        if not conn:
            logger.error("Database connection failed while resolving uid for %s", username)
            return None

        cursor = conn.cursor(as_dict=True)

        # Check if user already exists
        cursor.execute("SELECT uid FROM VmUsers WHERE username = %s", (username,))
        result = cursor.fetchone()
        if result:
            conn.close()
            return result['uid']

        # Assign a new UID starting from 2000
        cursor.execute("SELECT MAX(uid) AS max_uid FROM VmUsers")
        max_uid = cursor.fetchone()['max_uid'] or 1999
        new_uid = max_uid + 1

        # Insert new user
        cursor.execute("INSERT INTO VmUsers (username, uid) VALUES (%s, %s)", (username, new_uid))
        conn.commit()
        conn.close()

        return new_uid
    except Exception as e:
        logger.error("Failed to resolve uid for %s: %s", username, e)
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

    conn = None
    try:
        conn = get_db_connection()
        if not conn:
            logger.error("Database connection failed while releasing VMID %s after a failed checkout.", vmid)
            return False

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
    except Exception as e:
        logger.error("Error releasing VMID %s after a failed checkout: %s", vmid, e)
        return False
    finally:
        if conn:
            conn.close()

def generate_secure_password(length=25) -> str:
    characters = string.ascii_letters + string.digits + string.punctuation
    password = ''.join(secrets.choice(characters) for _ in range(length))
    return password

def is_member_of_group(service_principal_id, group_ids):
    access_token = get_access_token(TENANT_ID, CLIENT_ID, MICROSOFT_PROVIDER_AUTHENTICATION_SECRET)
    if not access_token:
        print("Cannot acquire access token for Graph API.")
        return False

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
        print("Graph API error: %s - %s", response.status_code, response.text)
        return False

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
    return is_member_of_group(user_oid, group_ids)
     
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
                    print("Authorization header is malformed. Expected 'Bearer <token>'.")

            if not token:
                print("Token is missing in the request.")
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
                    is_in_group = is_member_of_group(user_oid, required_group_ids)
                
                if not (has_scope_permission or has_role_permission or is_in_group):
                    print("Access denied: insufficient scope or role permissions or group membership.")
                    return jsonify({'message': 'Access denied: insufficient scope or role permissions or group membership.'}), 403

            except jwt.ExpiredSignatureError:
                print("Token has expired.")
                return jsonify({'message': 'Token has expired.'}), 401
            except jwt.InvalidAudienceError as e:
                print("Invalid audience: %s", e)
                return jsonify({'message': 'Invalid audience.'}), 401
            except jwt.InvalidIssuerError as e:
                print("Invalid issuer: %s", e)
                return jsonify({'message': 'Invalid issuer.'}), 401
            except Exception as e:
                print("Token validation error: %s", e)
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
    conn = get_db_connection()
    if not conn:
        logger.error("Database connection failed while reading Linux host settings.")
        return None

    try:
        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetLinuxHostSettings")
            row = cursor.fetchone()

        if not row:
            logger.error("No Linux host settings profile exists.")
            return None

        return normalize_host_settings(row)
    except Exception as e:
        logger.error("Error reading Linux host settings: %s", e)
        return None
    finally:
        conn.close()

def record_settings_applied(hostname: str, settings_version: int) -> bool:
    conn = get_db_connection()
    if not conn:
        logger.error("Database connection failed while recording applied settings for %s.", hostname)
        return False

    try:
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
    except Exception as e:
        logger.error("Error recording applied settings for %s: %s", hostname, e)
        return False
    finally:
        conn.close()

def apply_host_settings_to_host(hostname: str, settings: dict):
    """Push settings to one host over SSH.

    The document is written to the remote script's stdin rather than passed on the command
    line, mirroring how the password is delivered to chpasswd. That keeps the values out of
    the remote process list and leaves no shell-injection surface.
    """
    try:
        result, host_fqdn = run_remote_command(
            hostname,
            f"sudo {REMOTE_APPLY_SETTINGS_SCRIPT}",
            stdin_input=json.dumps(settings)
        )

        if result.returncode != 0:
            message = (result.stderr or result.stdout or '').strip()
            logger.error("Failed to apply host settings on '%s': %s", host_fqdn, message)
            return False, message or 'The remote apply script reported a failure.'

        record_settings_applied(hostname, settings['SettingsVersion'])
        return True, (result.stdout or '').strip()
    except Exception as e:
        logger.error("Error applying host settings on '%s': %s", hostname, e)
        return False, str(e)

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
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        cursor = conn.cursor(as_dict=True)
        cursor.execute("EXEC GetVms")
        rows = cursor.fetchall()
        conn.close()

        if not rows:
            return jsonify([]), 200

        return jsonify(serialize_for_json(rows)), 200

    except Exception as e:
        return f"An unexpected error occurred: {str(e)}", 500

@app.route('/api/vms/available', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
def get_available_vm():
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        cursor = conn.cursor(as_dict=True)
        query = """
        SELECT TOP 1 * FROM dbo.VirtualMachines
        WHERE PowerState = 'On' AND NetworkStatus = 'Reachable' AND VmStatus = 'Available'
        """
        cursor.execute(query)
        row = cursor.fetchone()
        conn.close()

        if not row:
            return "No available VM found.", 404

        available_vm = {
            "VMID": row["VMID"],
            "Hostname": row["Hostname"],
            "IPAddress": row["IPAddress"],
            "VmStatus": row["VmStatus"],
            "NetworkStatus": row["NetworkStatus"],
            "PowerState": row["PowerState"]
        }

        return jsonify(available_vm), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/vms/checkout', methods=['POST'])
@token_required(['AvdHost', 'access_as_user', 'FullAccess'], required_group_ids=[AVD_HOST_GROUP_ID])
def checkout_vm():
    try:
        req_body = request.get_json()

        username = req_body.get('username')
        avdhost = req_body.get('avdhost')

        if not username or not avdhost:
            return "Please provide 'username' and 'avdhost' in the request body.", 400

        username = re.sub(r'[^a-zA-Z0-9_]', '', username)
        user_password = generate_secure_password()

        conn = get_db_connection()
        try:
            with conn.cursor(as_dict=True) as cursor:
                cursor.callproc('CheckoutVm', (username, avdhost))
                rows = cursor.fetchall()
                conn.commit()
        finally:
            conn.close()

        if not rows or 'Message' in rows[0]:
            return "No available VM found. Please try again.", 409

        checked_out_vm = rows[0]
        vm_hostname = checked_out_vm.get('Hostname')
        lease_id = normalize_lease_id(checked_out_vm.get('LeaseId'))

        if not vm_hostname or not lease_id:
            return "No hostname or LeaseId found for the checked-out VM.", 500

        if not create_or_update_remote_user(vm_hostname, username, user_password, lease_id):
            release_vm_assignment(checked_out_vm.get("VMID"), lease_id)
            return f"Failed to create or update user '{username}' on VM '{vm_hostname}'.", 500
        
        groups_to_add = ["tsusers", "appusers"]

        if not remote_group_exists(vm_hostname, "tsusers"):
            if not create_remote_group(vm_hostname, "tsusers"):
                return f"Failed to create group 'tsusers' on VM '{vm_hostname}'.", 500

        if not remote_group_exists(vm_hostname, "appusers"):
            if not create_remote_group(vm_hostname, "appusers"):
                return f"Failed to create group 'appusers' on VM '{vm_hostname}'.", 500

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
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

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

        conn = get_db_connection()
        if not conn:
            return jsonify({'error': "Database connection failed."}), 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute(
                "EXEC UpdateVmAttributes @VMID = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s",
                (vmid, powerstate, networkstatus, vmstatus)
            )
            row = cursor.fetchone()
            conn.commit()
            if not row:
                return jsonify({'error': "VM not found or no attributes updated. Please try again."}), 404
        
        conn.close()

        return jsonify(row), 200

    except json.JSONDecodeError:
        return jsonify({'error': "Invalid JSON data"}), 400

    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/vms/<vmid>/delete', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def delete_vm(vmid):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC DeleteVm @VMID = %s", (vmid,))
            row = cursor.fetchone()

        conn.commit()
        conn.close()

        if not row:
            return f"VM with VMID {vmid} could not be deleted or was not found.", 404

        return f"VM with VMID {vmid} has been successfully deleted.", 200

    except Exception as e:
        return f"Error: {str(e)}", 500

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
            return "Please provide 'hostname', 'ipaddress', 'powerstate', 'networkstatus', and 'vmstatus' in the request body.", 400

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("""
                EXEC AddVm @Hostname = %s, @IPAddress = %s, @PowerState = %s, @NetworkStatus = %s, @VmStatus = %s,
                            @Username = %s, @AvdHost = %s, @Description = %s
            """, (hostname, ipaddress, powerstate, networkstatus, vmstatus, username, avdhost, description))

            row = cursor.fetchone()

        conn.commit()
        conn.close()

        if not row:
            return "Failed to add new VM. Please try again.", 500

        return jsonify({"NewVMID": row['NewVMID']}), 201

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/vms/<vmid>', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
def get_vm_details(vmid):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetVmDetails @VMID = %s", (vmid,))
            row = cursor.fetchone()
        conn.close()

        if not row:
            return f"VM with VMID {vmid} was not found.", 404

        return jsonify(serialize_for_json(row)), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/vms/<vmid>/return', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def return_vm(vmid):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC ReturnVm @VMID = %s", (vmid,))
            row = cursor.fetchone()
        conn.commit()
        conn.close()

        if not row:
            return f"VM with VMID {vmid} was not found or is not currently checked out.", 404

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

    except Exception as e:
        return f"Error: {str(e)}", 500

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

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute(
                "EXEC ReleaseVm @Hostname = %s, @LeaseId = %s, @Username = %s",
                (hostname, lease_id, username)
            )
            row = cursor.fetchone()
        
        conn.commit()
        conn.close()

        if not row:
            return f"Failed to release VM with Hostname {hostname}. Please try again.", 500

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

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/vms/released', methods=['POST'])
@token_required(['ScheduledTask', 'access_as_user', 'FullAccess'])
def return_released_vm_api():
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC ReturnReleasedVms")
            rows = cursor.fetchall()
        conn.commit()
        conn.close()

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

    except Exception as e:
        return f"Error: {str(e)}", 500


@app.route('/api/vms/history', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def get_vm_history():
    try:
        req_body = request.get_json()

        startdate = req_body.get('startdate', None)
        enddate = req_body.get('enddate', None)
        limit = req_body.get('limit', 100)

        startdate = None if startdate == 'null' else startdate
        enddate = None if enddate == 'null' else enddate

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetVmHistory @StartDate = %s, @EndDate = %s, @Limit = %s", (startdate, enddate, limit))
            rows = cursor.fetchall()
        conn.close()

        return jsonify(serialize_for_json(rows)), 200

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

# ===============================
# Scaling APIs

@app.route('/api/scaling/log', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_activity_log():
    try:
        req_body = request.get_json()

        startdate = req_body.get('startdate', None)
        enddate = req_body.get('enddate', None)
        limit = req_body.get('limit', 100)

        startdate = None if startdate == 'null' else startdate
        enddate = None if enddate == 'null' else enddate

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetScalingActivityLog @StartDate = %s, @EndDate = %s, @Limit = %s", (startdate, enddate, limit))
            rows = cursor.fetchall()

        conn.close()

        if not rows:
            return jsonify({"message": "No scaling activities found for the specified criteria."}), 200

        return jsonify(rows), 200

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/scaling/trigger', methods=['POST'])
@token_required(['ScheduledTask', 'access_as_user', 'FullAccess'])
def trigger_scaling_logic():
    try:
        if not VM_SUBSCRIPTION_ID or not VM_RESOURCE_GROUP:
            return "Configuration error: missing Azure subscription or resource group.", 500

        credential = DefaultAzureCredential()
        compute_client = ComputeManagementClient(credential=credential, subscription_id=VM_SUBSCRIPTION_ID)

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC TriggerScalingLogic")
            rows = cursor.fetchall()
        
        conn.close()

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

    except Exception as e:
        return f"Error: {str(e)}", 500

# ===============================
# Scaling Rules APIs

@app.route('/api/scaling/rules', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_rules():
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetScalingRules")
            rows = cursor.fetchall()
        conn.close()

        if not rows:
            return "No scaling rules found.", 404

        return jsonify(rows), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/scaling/rules/<int:ruleid>', methods=['GET'])
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_rule_details(ruleid):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetScalingRuleDetails @RuleID = %s", (ruleid,))
            row = cursor.fetchone()
        conn.close()

        if not row:
            return f"Scaling rule with RuleID {ruleid} was not found.", 404

        return jsonify(row), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

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
            return (
                "Please provide all required fields: 'minvms', 'maxvms', 'scaleupratio', "
                "'scaleupincrement', 'scaledownratio', 'scaledownincrement'.",
                400,
            )

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

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
        conn.close()

        if not row:
            return "Failed to create the scaling rule. Please try again.", 500

        new_rule_id = row.get('NewRuleID')

        return jsonify({"NewRuleID": new_rule_id}), 201

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

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
            return "Please provide at least one field to update.", 400

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor() as cursor:
            cursor.execute(
                """
                EXEC UpdateScalingRule @RuleID = %s, @MinVMs = %s, @MaxVMs = %s, @ScaleUpRatio = %s, 
                                    @ScaleUpIncrement = %s, @ScaleDownRatio = %s, @ScaleDownIncrement = %s
                """,
                (ruleid, minvms, maxvms, scaleupratio, scaleupincrement, scaledownratio, scaledownincrement),
            )
        conn.commit()
        conn.close()

        return f"Scaling rule with RuleID {ruleid} updated successfully.", 200

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/scaling/rules/<int:ruleid>/delete', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def delete_scaling_rule(ruleid):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC DeleteScalingRule @RuleID = %s", (ruleid,))
            row = cursor.fetchone()
        conn.commit()
        conn.close()

        if not row:
            return f"Scaling rule with RuleID {ruleid} could not be deleted or was not found.", 404

        return f"Scaling rule with RuleID {ruleid} has been successfully deleted.", 200

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/scaling/rules/history', methods=['POST'])
@token_required(['access_as_user', 'FullAccess'])
def get_scaling_rules_history():
    try:
        req_body = request.get_json()

        startdate = req_body.get('startdate', None)
        enddate = req_body.get('enddate', None)
        limit = req_body.get('limit', 100)

        startdate = None if startdate == 'null' else startdate
        enddate = None if enddate == 'null' else enddate

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC GetVMScalingRulesHistory @StartDate = %s, @EndDate = %s, @Limit = %s", (startdate, enddate, limit))
            rows = cursor.fetchall()
        conn.close()

        if not rows:
            return jsonify({"message": "No scaling activities found for the specified criteria."}), 200

        return jsonify(rows), 200

    except json.JSONDecodeError:
        return "Invalid JSON data", 400

    except Exception as e:
        return f"Error: {str(e)}", 500

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

    except Exception as e:
        return f"Error: {str(e)}", 500

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

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        try:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute(
                    "EXEC UpdateLinuxHostSettings "
                    "@GracePeriodSeconds = %s, @ReconcileIntervalSeconds = %s, "
                    "@WatcherDebounceSeconds = %s, @WatcherSettleSeconds = %s, "
                    "@IdleTimeoutSeconds = %s, @IdleWarningSeconds = %s, "
                    "@ScreenLockEnabled = %s, @ScreenIdleDelaySeconds = %s, "
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
                        settings.get('ScreenIdleDelaySeconds'),
                        settings.get('ScreenLockDelaySeconds'),
                        settings.get('ScreenLockSettingsLocked'),
                        updated_by
                    )
                )
                row = cursor.fetchone()

            conn.commit()
        finally:
            conn.close()

        if not row:
            return jsonify({'error': 'Unable to update Linux host settings.'}), 500

        return jsonify(normalize_host_settings(row)), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

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

        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        try:
            with conn.cursor(as_dict=True) as cursor:
                cursor.execute("EXEC GetVms")
                vms = cursor.fetchall()
        finally:
            conn.close()

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

    except Exception as e:
        return f"Error: {str(e)}", 500

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

    except Exception as e:
        return f"Error: {str(e)}", 500

# ===============================
# Main

password_refresh_thread = threading.Thread(target=refresh_db_password, args=(3600,), daemon=True)
password_refresh_thread.start()

if __name__ == '__main__':
    app.run(debug=True)
