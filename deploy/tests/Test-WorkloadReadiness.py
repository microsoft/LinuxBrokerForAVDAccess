"""Exercise real-operation readiness decisions with only HTTP boundaries mocked."""

import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("broker_workload_probe", Path(__file__).resolve().parents[1] / "Test-BrokerWorkloadAccess.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
API = "https://broker.example/api"
CLIENT = "aaaaaaaa-aaaa-4aaa-8aaa-000000000002"
TOKEN = "opaque-platform-token-do-not-log"


class Response:
    status = 200

    def __init__(self, value):
        self.value = value

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, limit):
        return json.dumps(self.value).encode()[:limit]


class ReadinessTests(unittest.TestCase):
    def invoke(self, workload, operation_result, environment=None, token_result=None, api_error=None):
        requests = []
        responses = [Response({"access_token": TOKEN} if token_result is None else token_result),
                     api_error or Response(operation_result)]

        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                result = responses.pop(0)
                if isinstance(result, Exception):
                    raise result
                return result

        result = probe.check_access(workload, API, CLIENT, environment or {}, lambda *handlers: Opener())
        return result, requests

    def test_host_proves_allowed_registered_settings_read(self):
        result, requests = self.invoke("LinuxHost", {"SettingsVersion": 1})
        self.assertEqual(result, "BROKER_WORKLOAD_READY")
        self.assertEqual(requests[0].get_header("Metadata"), "true")
        self.assertEqual(urlsplit(requests[0].full_url).hostname, "169.254.169.254")
        self.assertEqual(parse_qs(urlsplit(requests[0].full_url).query)["resource"], ["api://" + CLIENT])
        self.assertEqual(requests[1].full_url, API + "/hosts/settings")
        self.assertEqual(requests[1].get_header("Authorization"), "Bearer " + TOKEN)

    def test_task_uses_own_platform_identity_and_allowed_inventory(self):
        result, requests = self.invoke("ScheduledTask", [], {
            "IDENTITY_ENDPOINT": "http://127.0.0.1:8081/msi/token",
            "IDENTITY_HEADER": "platform-header-do-not-log"
        })
        self.assertEqual(result, "BROKER_WORKLOAD_READY")
        self.assertEqual(requests[0].get_header("X-identity-header"), "platform-header-do-not-log")
        self.assertEqual(parse_qs(urlsplit(requests[0].full_url).query)["api-version"], ["2019-08-01"])
        self.assertEqual(requests[1].full_url, API + "/vms")

    def test_roleless_cached_token_cannot_pass_on_token_acquisition_alone(self):
        for code in (401, 403):
            with self.subTest(code=code):
                error = HTTPError(API, code, "denied", {}, io.BytesIO(b"secret-body"))
                with self.assertRaisesRegex(probe.ProbeError, "not authorized yet"):
                    self.invoke("LinuxHost", {}, api_error=error)

    def test_no_token_claim_decoding_or_group_fallback(self):
        result, _ = self.invoke("LinuxHost", {"SettingsVersion": 1},
                                token_result={"access_token": "not-a-jwt", "roles": []})
        self.assertEqual(result, "BROKER_WORKLOAD_READY")
        # The token is opaque; only the authenticated server's policy decision establishes readiness.
        with self.assertRaises(probe.ProbeError):
            self.invoke("LinuxHost", {}, token_result={"roles": ["LinuxHost"], "groups": ["trusted-looking"]})

    def test_missing_function_identity_never_falls_back_to_operator_or_imds(self):
        for environment in ({}, {"IDENTITY_ENDPOINT": "http://127.0.0.1/token"}):
            with self.subTest(environment=environment), self.assertRaisesRegex(probe.ProbeError, "Do not substitute"):
                self.invoke("ScheduledTask", [], environment)

    def test_credentials_and_response_details_are_absent_from_errors(self):
        error = HTTPError(API, 403, "contains-secret", {}, io.BytesIO(TOKEN.encode()))
        with self.assertRaises(probe.ProbeError) as caught:
            self.invoke("LinuxHost", {}, api_error=error)
        self.assertNotIn(TOKEN, str(caught.exception))
        self.assertNotIn("contains-secret", str(caught.exception))

    def test_wrong_operation_shape_does_not_signal_readiness(self):
        for body in ({}, {"SettingsVersion": True}, {"SettingsVersion": 0}, []):
            with self.subTest(body=body), self.assertRaises(probe.ProbeError):
                self.invoke("LinuxHost", body)
        with self.assertRaises(probe.ProbeError):
            self.invoke("ScheduledTask", {"error": "not inventory"}, {
                "IDENTITY_ENDPOINT": "http://127.0.0.1/token", "IDENTITY_HEADER": "local"
            })

    def test_transient_or_redirect_api_results_do_not_authorize(self):
        for error in (URLError("network unavailable"), HTTPError(API, 302, "redirect", {}, None),
                      HTTPError(API, 503, "unavailable", {}, None)):
            with self.subTest(error=error), self.assertRaises(probe.ProbeError):
                self.invoke("LinuxHost", {}, api_error=error)

    def test_malformed_token_rejected_before_api(self):
        for token in ("", None, 123, TOKEN + "\n"):
            with self.subTest(token=token), self.assertRaises(probe.ProbeError):
                self.invoke("LinuxHost", {"SettingsVersion": 1}, token_result={"access_token": token})

    def test_no_api_calls_for_invalid_deployment_configuration(self):
        with mock.patch.object(probe, "build_opener") as opener:
            for api in ("http://broker.example/api", "https://user:password@broker.example/api",
                        "https://broker.example/api?secret=x", "https://broker.example"):
                with self.subTest(api=api), self.assertRaises(probe.ProbeError):
                    probe.check_access("LinuxHost", api, CLIENT, {}, opener_factory=opener)
            opener.assert_not_called()

    def test_proxy_bypass_is_only_for_platform_identity_endpoint(self):
        factories = []

        def factory(*handlers):
            factories.append(handlers)
            response = {"access_token": TOKEN} if len(factories) == 1 else {"SettingsVersion": 1}
            return type("Opener", (), {"open": lambda self, *args, **kwargs: Response(response)})()

        probe.check_access("LinuxHost", API, CLIENT, {}, factory)
        self.assertTrue(any(isinstance(handler, probe.ProxyHandler) and not handler.proxies for handler in factories[0]))
        self.assertTrue(all(not isinstance(handler, probe.ProxyHandler) for handler in factories[1]))
        self.assertTrue(all(any(isinstance(handler, probe.NoRedirect) for handler in handlers) for handlers in factories))


if __name__ == "__main__":
    unittest.main()
