import importlib

import pytest

import function_app


class FakeResponse:
    def __init__(self, status_code=200, data=None, text=""):
        self.status_code = status_code
        self._data = data
        self.text = text

    def json(self):
        return self._data


class FakeConnection:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


def test_parse_probe_ports_defensively():
    assert function_app.parse_probe_ports(None) == [22]
    assert function_app.parse_probe_ports("22, 3389") == [22, 3389]
    assert function_app.parse_probe_ports("22,,3389") == [22]
    assert function_app.parse_probe_ports("0") == [22]
    assert function_app.parse_probe_ports("65536") == [22]
    assert function_app.parse_probe_ports("abc") == [22]


def test_probe_host_requires_all_ports_and_passes_timeout():
    calls = []

    def connector(address, timeout):
        calls.append((address, timeout))
        if address[1] == 443:
            raise TimeoutError("timed out")
        return FakeConnection()

    assert function_app.probe_host("10.0.0.4", [22], 1.5, connector) is True
    assert function_app.probe_host("10.0.0.4", [22, 443], 1.5, connector) is False
    assert calls == [
        (("10.0.0.4", 22), 1.5),
        (("10.0.0.4", 22), 1.5),
        (("10.0.0.4", 443), 1.5),
    ]


def test_off_hosts_are_not_probed_and_are_unreachable():
    vms = [
        {"VMID": 1, "IPAddress": "10.0.0.1", "PowerState": "Off", "NetworkStatus": "Reachable"},
        {"VMID": 2, "IPAddress": "10.0.0.2", "PowerState": "On", "NetworkStatus": "Unreachable"},
        {"VMID": 3, "PowerState": "On", "NetworkStatus": "Reachable"},
    ]

    targets, skipped = function_app.get_probe_targets(vms)
    updates = function_app.plan_network_updates(vms, {2: "Reachable"})

    assert skipped == 1
    assert [vm["VMID"] for vm in targets] == [2]
    assert updates == [
        {"vm_id": 1, "networkstatus": "Unreachable"},
        {"vm_id": 2, "networkstatus": "Reachable"},
    ]


def test_only_changed_updates_are_planned():
    vms = [
        {"VMID": "same", "IPAddress": "10.0.0.1", "PowerState": "On", "NetworkStatus": "Reachable"},
        {"VMID": "changed", "IPAddress": "10.0.0.2", "PowerState": "On", "NetworkStatus": "Reachable"},
    ]

    assert function_app.plan_network_updates(
        vms,
        {"same": "Reachable", "changed": "Unreachable"},
    ) == [{"vm_id": "changed", "networkstatus": "Unreachable"}]


def test_network_status_404_fallback_is_remembered(monkeypatch):
    vms = [
        {"VMID": "one", "IPAddress": "10.0.0.1", "PowerState": "On", "NetworkStatus": "Unreachable"},
        {"VMID": "two", "IPAddress": "10.0.0.2", "PowerState": "On", "NetworkStatus": "Unreachable"},
    ]
    post_urls = []

    monkeypatch.setattr(function_app.requests, "get", lambda *_args, **_kwargs: FakeResponse(200, vms))
    monkeypatch.setattr(
        function_app,
        "run_probes",
        lambda *_args, **_kwargs: {"one": "Reachable", "two": "Reachable"},
    )

    def post(url, **kwargs):
        post_urls.append(url)
        if url.endswith("/vms/one/network-status"):
            return FakeResponse(404)
        return FakeResponse(200)

    monkeypatch.setattr(function_app.requests, "post", post)

    function_app.test_vm_connectivity(function_app.func.TimerRequest())

    assert post_urls == [
        "https://broker.example/api/vms/one/network-status",
        "https://broker.example/api/vms/one/update-attributes",
        "https://broker.example/api/vms/two/update-attributes",
    ]


def test_request_timeouts_are_passed(monkeypatch):
    calls = []

    def get(url, **kwargs):
        calls.append(("get", url, kwargs["timeout"]))
        return FakeResponse(200, [])

    def post(url, **kwargs):
        calls.append(("post", url, kwargs["timeout"]))
        return FakeResponse(200)

    monkeypatch.setattr(function_app.requests, "get", get)
    monkeypatch.setattr(function_app.requests, "post", post)

    timer = function_app.func.TimerRequest()
    function_app.test_vm_connectivity(timer)
    function_app.trigger_return_released_vms(timer)
    function_app.time_triggered_scaling(timer)
    function_app.purge_audit_log(timer)

    assert calls == [
        ("get", "https://broker.example/api/vms", 30),
        ("post", "https://broker.example/api/vms/released", 120),
        ("post", "https://broker.example/api/scaling/trigger", 120),
        ("post", "https://broker.example/api/audit/purge", 120),
    ]


@pytest.mark.parametrize("status,level,text", [
    (200, "INFO", "Audit log purge completed"),
    (404, "WARNING", "does not have an audit log yet"),
    (500, "ERROR", "Failed to purge the audit log"),
])
def test_the_audit_purge_reports_its_outcome(monkeypatch, caplog, status, level, text):
    monkeypatch.setattr(function_app.requests, "post", lambda *_args, **_kwargs: FakeResponse(status, text='{"Deleted": 3}'))

    with caplog.at_level("INFO"):
        function_app.purge_audit_log(function_app.func.TimerRequest())

    assert any(record.levelname == level and text in record.getMessage() for record in caplog.records)


def test_timer_functions_tolerate_api_errors(monkeypatch):
    def raise_error(*_args, **_kwargs):
        raise RuntimeError("api down")

    monkeypatch.setattr(function_app.requests, "get", raise_error)
    monkeypatch.setattr(function_app.requests, "post", raise_error)

    timer = function_app.func.TimerRequest(past_due=True)
    function_app.test_vm_connectivity(timer)
    function_app.trigger_return_released_vms(timer)
    function_app.time_triggered_scaling(timer)
    function_app.purge_audit_log(timer)


def test_fake_modules_are_used():
    reloaded = importlib.reload(function_app)
    assert reloaded.get_access_token() == "fake-token"
