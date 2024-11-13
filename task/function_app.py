import requests
import logging
import os

import azure.functions as func
from azure.identity import ManagedIdentityCredential

# version  - 0.11

app = func.FunctionApp()

API_BASE_URL = os.getenv("API_URL")
API_CLIENT_ID = os.getenv("API_CLIENT_ID")
API_APP_URI = f"api://{API_CLIENT_ID}"
credential = ManagedIdentityCredential()

def get_access_token():
    try:
        token = credential.get_token(f"{API_APP_URI}/.default")
        return token.token
    except Exception as e:
        logging.error(f"Error obtaining access token: {str(e)}")
        return None

def get_headers():
    access_token = get_access_token()
    if not access_token:
        logging.error("Could not obtain access token.")
        return None
    headers = {
        'Authorization': f'Bearer {access_token}'
    }
    return headers

# ===============================
# VM Management Tasks
# ===============================


@app.function_name(name="ReturnReleasedVMs")
@app.timer_trigger(schedule="0 * * * * *",  # Every minute
              arg_name="mytimer", run_on_startup=True)
def trigger_return_released_vms(mytimer: func.TimerRequest) -> None:
    logging.info('Running scheduled check for released VMs to return.')
    if mytimer.past_due:
        logging.info('The timer is past due!')

    try:

        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return
        
        headers = get_headers()
        if headers is None:
            return

        # Construct the full API URL
        check_and_return_url = f"{API_BASE_URL}/vms/released"

        # Make an HTTP POST request to the API
        response = requests.post(check_and_return_url, headers=headers)

        if response.status_code == 200:
            logging.info("Check and return logic triggered successfully.")
        else:
            logging.error(f"Failed to trigger check and return logic. Status code: {response.status_code}. Response: {response.text}")

    except Exception as e:
        logging.error(f"Error executing time-triggered check and return logic: {str(e)}")

@app.function_name(name="TestVMConnectivity")
@app.timer_trigger(schedule="0 0 * * * *",  # Every hour at the top of the hour
                 arg_name="mytimer", run_on_startup=True)
def test_vm_connectivity(mytimer: func.TimerRequest) -> None:
    logging.info('TestVMConnectivity function started.')

    if mytimer.past_due:
        logging.info('The timer is past due!')

    try:
        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return

        headers = get_headers()
        if headers is None:
            return
        
        # Construct the API URL for fetching all VMs
        get_all_vms_url = f"{API_BASE_URL}/vms"

        # Make an HTTP GET request to the API to fetch all VMs
        response = requests.get(get_all_vms_url, headers=headers)

        if response.status_code != 200:
            logging.error(f"Failed to retrieve VMs. Status code: {response.status_code}")
            return

        vms = response.json()

        # Iterate over each VM and test connectivity
        for vm in vms:
            vm_id = vm.get('VMID')
            ip_address = vm.get('IPAddress')

            if not ip_address:
                logging.warning(f"No IP address found for VMID: {vm_id}")
                continue

            # Use os.system to test connectivity to port 22 using curl
            try:
                # Command to test port 22 with curl
                command = f"curl -v telnet://{ip_address}:22 > /dev/null 2>&1"
                
                # Execute the command using os.system
                response_code = os.system(command)

                # Determine network status based on the result of the curl command
                network_status = 'Reachable' if response_code == 0 else 'Unreachable'
                logging.info(f"VMID: {vm_id}, IP Address: {ip_address}, Network Status: {network_status}")

            except Exception as e:
                logging.error(f"Error testing connectivity for VMID: {vm_id}: {str(e)}")
                network_status = 'Unreachable'

            # Prepare the data for updating VM attributes
            update_data = {
                "vmid": vm_id,
                "powerstate": "null",  # No change to PowerState
                "networkstatus": network_status,  # Update NetworkStatus
                "vmstatus": "null"  # No change to VmStatus
            }

            # Construct the API URL for updating VM attributes
            update_vm_url = f"{API_BASE_URL}/vms/{vm_id}/update-attributes"

            # Make an HTTP POST request to the API to update the network status
            response = requests.post(update_vm_url, headers=headers, json=update_data)

            if response.status_code == 200:
                logging.info(f"Updated network status for VMID: {vm_id} to {network_status}.")
            else:
                logging.error(f"Failed to update network status for VMID: {vm_id}. Status code: {response.status_code}")

        logging.info('TestVMConnectivity function completed.')

    except Exception as e:
        logging.error(f"Error executing TestVMConnectivity function: {str(e)}")


# ===============================
# Scaling Tasks
# ===============================

# Scaling logic triggered every 5 minutes
@app.function_name(name="ScalingVMs")
@app.timer_trigger(schedule="0 */5 * * * *",  # Every 5 minutes
              arg_name="mytimer",
              run_on_startup=True) 
def time_triggered_scaling(mytimer: func.TimerRequest) -> None:
    logging.info('Time-triggered scaling logic execution started.')

    if mytimer.past_due:
        logging.info('The timer is past due!')

    try:

        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return

        headers = get_headers()
        if headers is None:
            return
        
        # Construct the full API URL
        scaling_api_url = f"{API_BASE_URL}/scaling/trigger"

        # Make an HTTP POST request to the API
        response = requests.post(scaling_api_url, headers=headers)

        if response.status_code == 200:
            logging.info("Scaling logic triggered successfully.")
        else:
            logging.error(f"Failed to trigger scaling logic. Status code: {response.status_code}. Response: {response.text}")

    except Exception as e:
        logging.error(f"Error executing time-triggered scaling logic: {str(e)}")