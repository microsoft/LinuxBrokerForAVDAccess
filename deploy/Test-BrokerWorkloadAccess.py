"""Probe an allowed broker operation with the local platform's managed identity."""

import argparse
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class ProbeError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def read_json(opener, request, limit, label):
    try:
        with opener.open(request, timeout=30) as response:
            if response.status != 200:
                raise ProbeError("{} did not return HTTP 200.".format(label))
            content = response.read(limit + 1)
            if len(content) > limit:
                raise ProbeError("{} response exceeded its safe size limit.".format(label))
            return json.loads(content)
    except HTTPError as error:
        if error.code in (401, 403):
            raise ProbeError(
                "{} is not authorized yet (HTTP {}). Keep workloads disabled; "
                "allow managed-identity permission/token caches to refresh and rerun the actual-operation probe.".format(label, error.code))
        raise ProbeError("{} failed (HTTP {}). No response body was logged.".format(label, error.code))
    except (URLError, OSError, ValueError):
        raise ProbeError("{} could not be verified. No token or response body was logged.".format(label))


def check_access(workload, api_base_url, api_client_id, environment=None, opener_factory=build_opener):
    environment = os.environ if environment is None else environment
    api = urlsplit(api_base_url)
    if (api.scheme != "https" or not api.hostname or api.username or api.password
            or api.query or api.fragment or not api.path.rstrip("/").endswith("/api")):
        raise ProbeError("An explicit HTTPS broker API URL ending in /api is required.")
    import uuid
    try:
        parsed_id = uuid.UUID(api_client_id)
        if not parsed_id.int or str(parsed_id) != api_client_id.lower():
            raise ValueError("noncanonical")
    except (ValueError, TypeError, AttributeError):
        raise ProbeError("A canonical API client GUID is required.")
    resource = "api://" + api_client_id
    local_opener = opener_factory(ProxyHandler({}), NoRedirect())
    if workload == "LinuxHost":
        token_url = "http://169.254.169.254/metadata/identity/oauth2/token?" + urlencode({
            "api-version": "2018-02-01", "resource": resource})
        token_request = Request(token_url, headers={"Metadata": "true"})
        operation = "/hosts/settings"
    elif workload == "ScheduledTask":
        endpoint = environment.get("IDENTITY_ENDPOINT")
        identity_header = environment.get("IDENTITY_HEADER")
        if not endpoint or not identity_header:
            raise ProbeError(
                "The Function App's platform managed-identity endpoint is unavailable in this process. "
                "Do not substitute operator credentials; keep scheduled functions disabled.")
        parsed = urlsplit(endpoint)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise ProbeError("The platform identity endpoint is malformed.")
        query = urlencode({"api-version": "2019-08-01", "resource": resource})
        token_url = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, query, ""))
        token_request = Request(token_url, headers={"X-IDENTITY-HEADER": identity_header})
        operation = "/vms"
    else:
        raise ProbeError("Unsupported workload probe.")
    token_response = read_json(local_opener, token_request, 65536, "Managed identity token acquisition")
    token = token_response.get("access_token") if isinstance(token_response, dict) else None
    if not isinstance(token, str) or not token or "\r" in token or "\n" in token:
        raise ProbeError("The platform did not return a usable managed-identity access token.")
    api_opener = opener_factory(NoRedirect())
    result = read_json(api_opener, Request(api_base_url.rstrip("/") + operation, headers={
        "Authorization": "Bearer " + token, "Accept": "application/json", "Cache-Control": "no-store"
    }), 16 * 1024 * 1024, workload + " allowed-operation probe")
    if workload == "LinuxHost":
        if not isinstance(result, dict) or type(result.get("SettingsVersion")) is not int or result["SettingsVersion"] < 1:
            raise ProbeError("The allowed settings operation did not return a valid settings profile.")
    elif not isinstance(result, list):
        raise ProbeError("The scheduled inventory operation did not return a valid inventory list.")
    # Effective API authorization, not a decoded role claim, is the evidence of readiness.
    return "BROKER_WORKLOAD_READY"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True, choices=("LinuxHost", "ScheduledTask"))
    parser.add_argument("--api-base-url", required=True)
    parser.add_argument("--api-client-id", required=True)
    args = parser.parse_args()
    try:
        print(check_access(args.workload, args.api_base_url, args.api_client_id))
        return 0
    except ProbeError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
