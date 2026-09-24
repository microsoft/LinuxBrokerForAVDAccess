import concurrent.futures
import logging
import os
import socket

import requests

import azure.functions as func
from azure.identity import ManagedIdentityCredential

# version  - 0.12

app = func.FunctionApp()

API_BASE_URL = os.getenv("API_URL")
API_CLIENT_ID = os.getenv("API_CLIENT_ID")
API_APP_URI = f"api://{API_CLIENT_ID}"
credential = ManagedIdentityCredential()

DEFAULT_REQUEST_TIMEOUT_SECONDS = 30
LONG_REQUEST_TIMEOUT_SECONDS = 120
DEFAULT_PROBE_CONCURRENCY = 16
DEFAULT_PROBE_TIMEOUT_SECONDS = 3.0
DEFAULT_PROBE_PORTS = (22,)
MIN_PROBE_TIMEOUT_SECONDS = 0.1
MAX_PROBE_TIMEOUT_SECONDS = 30.0
MIN_PROBE_CONCURRENCY = 1
MAX_PROBE_CONCURRENCY = 64


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
    return {"Authorization": f"Bearer {access_token}"}


def api_url(path):
    if not API_BASE_URL:
        return None
    return f"{API_BASE_URL.rstrip('/')}/{path.lstrip('/')}"


def parse_probe_ports(value, default=DEFAULT_PROBE_PORTS):
    if value is None or str(value).strip() == "":
        return list(default)

    ports = []
    try:
        for raw_port in str(value).split(","):
            raw_port = raw_port.strip()
            if not raw_port:
                raise ValueError("empty port")
            port = int(raw_port)
            if port < 1 or port > 65535:
                raise ValueError("port out of range")
            ports.append(port)
    except (TypeError, ValueError):
        logging.warning("Invalid PROBE_PORTS value; using default.")
        return list(default)

    return ports or list(default)


def parse_probe_concurrency(value, default=DEFAULT_PROBE_CONCURRENCY):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return max(MIN_PROBE_CONCURRENCY, min(parsed, MAX_PROBE_CONCURRENCY))


def parse_probe_timeout(value, default=DEFAULT_PROBE_TIMEOUT_SECONDS):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    return max(MIN_PROBE_TIMEOUT_SECONDS, min(parsed, MAX_PROBE_TIMEOUT_SECONDS))


def get_probe_settings():
    return {
        "concurrency": parse_probe_concurrency(os.getenv("PROBE_CONCURRENCY")),
        "timeout": parse_probe_timeout(os.getenv("PROBE_TIMEOUT_SECONDS")),
        "ports": parse_probe_ports(os.getenv("PROBE_PORTS")),
    }


def _close_connection(connection):
    close = getattr(connection, "close", None)
    if callable(close):
        close()


def probe_host(ip_address, ports, timeout, connector=socket.create_connection):
    for port in ports:
        connection = None
        try:
            connection = connector((ip_address, port), timeout=timeout)
            enter = getattr(connection, "__enter__", None)
            exit_context = getattr(connection, "__exit__", None)
            if callable(enter) and callable(exit_context):
                with connection:
                    pass
            else:
                _close_connection(connection)
        except Exception:
            return False
    return True


def is_power_state_off(vm):
    return str(vm.get("PowerState") or "").strip().lower() == "off"


def get_vm_id(vm):
    return vm.get("VMID")


def get_probe_targets(vms):
    targets = []
    skipped_missing_ip = 0
    for vm in vms:
        vm_id = get_vm_id(vm)
        if not vm.get("IPAddress"):
            logging.warning(f"No IP address found for VMID: {vm_id}")
            skipped_missing_ip += 1
            continue
        if is_power_state_off(vm):
            continue
        targets.append(vm)
    return targets, skipped_missing_ip


def run_probes(vms, ports, timeout, concurrency, connector=socket.create_connection):
    results = {}
    if not vms:
        return results

    workers = max(MIN_PROBE_CONCURRENCY, min(concurrency, len(vms), MAX_PROBE_CONCURRENCY))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_vm = {
            executor.submit(probe_host, vm.get("IPAddress"), ports, timeout, connector): vm
            for vm in vms
        }
        for future in concurrent.futures.as_completed(future_to_vm):
            vm = future_to_vm[future]
            vm_id = get_vm_id(vm)
            try:
                results[vm_id] = "Reachable" if future.result() else "Unreachable"
            except Exception as e:
                logging.error(f"Error testing connectivity for VMID: {vm_id}: {str(e)}")
                results[vm_id] = "Unreachable"
    return results


def plan_network_updates(vms, probe_results):
    updates = []
    for vm in vms:
        vm_id = get_vm_id(vm)
        if not vm.get("IPAddress"):
            continue

        if is_power_state_off(vm):
            network_status = "Unreachable"
        else:
            network_status = probe_results.get(vm_id, "Unreachable")

        if vm.get("NetworkStatus") != network_status:
            updates.append({"vm_id": vm_id, "networkstatus": network_status})
    return updates


def post_network_status(vm_id, network_status, headers, use_fallback=False):
    if use_fallback:
        update_url = api_url(f"vms/{vm_id}/update-attributes")
        update_data = {
            "powerstate": None,
            "networkstatus": network_status,
            "vmstatus": None,
        }
        response = requests.post(
            update_url,
            headers=headers,
            json=update_data,
            timeout=DEFAULT_REQUEST_TIMEOUT_SECONDS,
        )
        return response, True

    response = requests.post(
        api_url(f"vms/{vm_id}/network-status"),
        headers=headers,
        json={"networkstatus": network_status},
        timeout=DEFAULT_REQUEST_TIMEOUT_SECONDS,
    )
    if response.status_code != 404:
        return response, False

    update_url = api_url(f"vms/{vm_id}/update-attributes")
    update_data = {
        "powerstate": None,
        "networkstatus": network_status,
        "vmstatus": None,
    }
    fallback_response = requests.post(
        update_url,
        headers=headers,
        json=update_data,
        timeout=DEFAULT_REQUEST_TIMEOUT_SECONDS,
    )
    return fallback_response, True


# ===============================
# VM Management Tasks
# ===============================


@app.function_name(name="ReturnReleasedVMs")
@app.timer_trigger(schedule="0 * * * * *", arg_name="mytimer", run_on_startup=True)
def ReturnReleasedVMs(mytimer: func.TimerRequest) -> None:
    logging.info("Running scheduled check for released VMs to return.")
    if mytimer.past_due:
        logging.info("The timer is past due!")

    try:
        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return

        headers = get_headers()
        if headers is None:
            return

        response = requests.post(
            api_url("vms/released"),
            headers=headers,
            timeout=LONG_REQUEST_TIMEOUT_SECONDS,
        )

        if response.status_code == 200:
            logging.info("Check and return logic triggered successfully.")
        else:
            logging.error(
                f"Failed to trigger check and return logic. Status code: {response.status_code}. Response: {response.text}"
            )
    except Exception as e:
        logging.error(f"Error executing time-triggered check and return logic: {str(e)}")


@app.function_name(name="TestVMConnectivity")
@app.timer_trigger(schedule="0 */2 * * * *", arg_name="mytimer", run_on_startup=True)
def TestVMConnectivity(mytimer: func.TimerRequest) -> None:
    logging.info("TestVMConnectivity function started.")

    if mytimer.past_due:
        logging.info("The timer is past due!")

    probed = 0
    changed = 0
    failed = 0

    try:
        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return

        headers = get_headers()
        if headers is None:
            return

        response = requests.get(
            api_url("vms"),
            headers=headers,
            timeout=DEFAULT_REQUEST_TIMEOUT_SECONDS,
        )

        if response.status_code != 200:
            logging.error(f"Failed to retrieve VMs. Status code: {response.status_code}")
            return

        vms = response.json()
        if not isinstance(vms, list):
            logging.error("Failed to retrieve VMs. Response was not a JSON array.")
            return

        settings = get_probe_settings()
        probe_targets, _ = get_probe_targets(vms)
        probed = len(probe_targets)
        probe_results = run_probes(
            probe_targets,
            settings["ports"],
            settings["timeout"],
            settings["concurrency"],
        )
        updates = plan_network_updates(vms, probe_results)

        use_update_attributes_fallback = False
        for update in updates:
            vm_id = update["vm_id"]
            network_status = update["networkstatus"]
            try:
                update_response, use_update_attributes_fallback = post_network_status(
                    vm_id,
                    network_status,
                    headers,
                    use_update_attributes_fallback,
                )
                if 200 <= update_response.status_code < 300:
                    changed += 1
                    logging.info(f"Updated network status for VMID: {vm_id} to {network_status}.")
                else:
                    failed += 1
                    logging.error(
                        f"Failed to update network status for VMID: {vm_id}. Status code: {update_response.status_code}"
                    )
            except Exception as e:
                failed += 1
                logging.error(f"Error updating network status for VMID: {vm_id}: {str(e)}")
    except Exception as e:
        failed += 1
        logging.error(f"Error executing TestVMConnectivity function: {str(e)}")
    finally:
        logging.info(f"TestVMConnectivity summary: probed={probed}, changed={changed}, failed={failed}")


# ===============================
# Scaling Tasks
# ===============================


@app.function_name(name="ScalingVMs")
@app.timer_trigger(schedule="0 */5 * * * *", arg_name="mytimer", run_on_startup=True)
def ScalingVMs(mytimer: func.TimerRequest) -> None:
    logging.info("Time-triggered scaling logic execution started.")

    if mytimer.past_due:
        logging.info("The timer is past due!")

    try:
        if not API_BASE_URL:
            logging.error("API_URL not set in environment variables.")
            return

        headers = get_headers()
        if headers is None:
            return

        response = requests.post(
            api_url("scaling/trigger"),
            headers=headers,
            timeout=LONG_REQUEST_TIMEOUT_SECONDS,
        )

        if response.status_code == 200:
            logging.info("Scaling logic triggered successfully.")
        else:
            logging.error(
                f"Failed to trigger scaling logic. Status code: {response.status_code}. Response: {response.text}"
            )
    except Exception as e:
        logging.error(f"Error executing time-triggered scaling logic: {str(e)}")


trigger_return_released_vms = ReturnReleasedVMs
test_vm_connectivity = TestVMConnectivity
time_triggered_scaling = ScalingVMs
