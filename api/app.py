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
app.config['VERSION'] = '0.155'

cache = Cache(app, config={'CACHE_TYPE': 'simple'})

# ===============================
# Logging Configuration

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    headers = {
        "Content-Type": "application/x-www-form-urlencoded"
    }
    data = {
        "client_id": client_id,
        "scope": "https://graph.microsoft.com/.default",
        "client_secret": client_secret,
        "grant_type": "client_credentials"
    }
    
    response = requests.post(url, headers=headers, data=data)
    if response.status_code == 200:
        return response.json().get("access_token")
    else:
        response.raise_for_status()

def create_or_update_remote_user(hostname: str, username: str, password: str) -> bool:
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        check_create_user_command = f"sudo id -u {username} >/dev/null 2>&1 || sudo useradd {username} -m"
        set_password_command = f"echo '{username}:{password}' | sudo chpasswd"
        command = f"{check_create_user_command} && {set_password_command}"

        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, command],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            return True
        else:
            print("Failed to create or update user '%s' on VM '%s'. Error: %s", username, host_fqdn, result.stderr)
            return False
    except Exception as e:
        print("Error creating or updating user '%s' on VM '%s': %s", username, host_fqdn, e)
        return False

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

    url = f"https://graph.microsoft.com/v1.0/servicePrincipals/{service_principal_id}/checkMemberGroups"

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

def delete_remote_user(hostname: str, username: str) -> bool:
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        delete_user_command = f"sudo userdel -r {username} 2>/dev/null || echo 'User {username} does not exist'"

        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, delete_user_command],
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            return True
        else:
            print(f"Failed to delete user '{username}' on VM '{hostname}'. Error: {result.stderr}")
            return False
    except Exception as e:
        print(f"Error deleting user '{username}' on VM '{hostname}': {e}")
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
                jwks_uri = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"
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
                    f"https://login.microsoftonline.com/{TENANT_ID}/v2.0",
                    f"https://login.microsoftonline.com/{TENANT_ID}/",
                    f"https://sts.windows.net/{TENANT_ID}/"
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
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, f'getent group {group_name}'],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            return True
        else:
            print("Group '%s' does not exist on VM '%s'. Error: %s", group_name, host_fqdn, result.stderr)
            return False
    except Exception as e:
        print("Error checking group '%s' on VM '%s': %s", group_name, host_fqdn, e)
        return False

def create_remote_group(hostname: str, group_name: str) -> bool:
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, f'sudo groupadd {group_name}'],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            return True
        else:
            print("Failed to create group '%s' on VM '%s'. Error: %s", group_name, host_fqdn, result.stderr)
            return False
    except Exception as e:
        print("Error creating group '%s' on VM '%s': %s", group_name, host_fqdn, e)
        return False

def is_user_in_remote_group(hostname: str, username: str, group_name: str) -> bool:
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, f'id -nG {username}'], 
            capture_output=True, 
            text=True
        )
        if result.returncode == 0:
            groups = result.stdout.strip().split()
            if group_name in groups:
                return True
            else:
                return False
        else:
            print("Error checking user '%s' on VM '%s': %s", username, host_fqdn, result.stderr)
            return False
    except Exception as e:
        print("Error checking user '%s' in group '%s' on VM '%s': %s", username, group_name, host_fqdn, e)
        return False

def add_user_to_remote_group(hostname: str, username: str, group_name: str) -> None:
    pem_file_path = retrieve_pem_key_from_key_vault(VAULT_URL, KEY_NAME)

    try:
        host_fqdn = f"avdadmin@{hostname}.{DOMAIN_NAME}"
        result = subprocess.run(
            ['ssh', '-i', pem_file_path, '-o', 'StrictHostKeyChecking=no', host_fqdn, f'sudo usermod -aG {group_name} {username}'], 
            capture_output=True, 
            text=True
        )
        if result.returncode != 0:
            print("Failed to add user '%s' to group '%s' on VM '%s': %s", username, group_name, host_fqdn, result.stderr)
    except Exception as e:
        print("Error adding user '%s' to group '%s' on VM '%s': %s", username, group_name, host_fqdn, e)

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
            return "No VMs found.", 404

        return jsonify(rows), 200

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

        if not vm_hostname:
            return "No hostname found for the checked-out VM.", 500

        if not create_or_update_remote_user(vm_hostname, username, user_password):
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
            "password": user_password
        }

        #print(f"================= Response data: {response_data}")    

        return jsonify(response_data), 200

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

        return jsonify(row), 200

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

        return jsonify(row), 200

    except Exception as e:
        return f"Error: {str(e)}", 500

@app.route('/api/vms/<hostname>/release', methods=['POST'])
@token_required(['LinuxHost', 'access_as_user', 'FullAccess'], required_group_ids=[LINUX_HOST_GROUP_ID])
def release_vm(hostname):
    try:
        conn = get_db_connection()
        if not conn:
            return "Database connection failed.", 500

        with conn.cursor(as_dict=True) as cursor:
            cursor.execute("EXEC ReleaseVm @Hostname = %s", (hostname,))
            row = cursor.fetchone()
        
        conn.commit()
        conn.close()

        if not row:
            return f"Failed to release VM with Hostname {hostname}. Please try again.", 500

        return jsonify(row), 200

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
            username = row.get("Username")

            if hostname and username:
                success = delete_remote_user(hostname, username)
                if success:
                    print(f"Successfully deleted user {username} from {hostname}")
                else:
                    print(f"Failed to delete user {username} from {hostname}")

        return jsonify(rows), 200

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

        return jsonify(rows), 200

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
# Main

password_refresh_thread = threading.Thread(target=refresh_db_password, args=(3600,), daemon=True)
password_refresh_thread.start()

if __name__ == '__main__':
    app.run(debug=True)
