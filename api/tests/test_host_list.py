"""2.7 the host list: server-side paging behind the unchanged bare list, and importing tagged
Linux host VMs from Azure, which must resolve in DNS."""

import json
import types

import pytest


def page_row(hostname, **values):
    row = {"VMID": 1, "Hostname": hostname, "IPAddress": "10.0.0.4", "PowerState": "On", "NetworkStatus": "Reachable",
           "VmStatus": "CheckedOut", "Username": "alice", "Ready": False, "CleanupPending": False, "DrainRequested": False,
           "SettingsVersion": 3, "CurrentSettingsVersion": 3, "AgentVersion": "1.1.0", "HeartbeatAgeSeconds": 20,
           "ReconcileIntervalSeconds": 60, "SessionsJson": json.dumps([{"username": "Alice", "state": "disconnected"}]),
           "TotalCount": 41}
    row.update(values)
    return row


def test_without_paging_the_bare_list_is_unchanged(client, fake_db):
    assert client.get("/api/vms").get_json() == [{"VMID": 1, "Hostname": "linux-01"}]
    assert [call["proc"] for call in fake_db.calls] == ["GetVms"]


def test_a_page_is_filtered_sorted_and_counted_in_sql(client, fake_db):
    fake_db.fetchall_rows["GetVmsPaged"] = [
        page_row("lnx-01"),
        page_row("lnx-02", VMID=2, Username=None, VmStatus="Available", Ready=True, SessionsJson="[]", SettingsVersion=2,
                 AgentVersion="1.0.0"),
        page_row("lnx-03", VMID=3, HeartbeatAgeSeconds=None, SessionsJson=None, AgentVersion=None),
    ]
    fake_db.fetchone_rows["GetVmStatusCounts"] = {"All": 41, "Ready": 10, "InUse": 20, "Released": 1, "Maintenance": 2,
                                                  "Draining": 3, "Unreachable": 4, "Off": 5, "Cleanup": 0}

    body = client.get("/api/vms?page=2&per_page=20&q=%20lnx%20&status=IN-USE&sort=heartbeat&dir=desc").get_json()

    assert fake_db.latest_call("GetVmsPaged")["params"] == ("lnx", "in-use", "heartbeat", True, 20, 20)
    assert fake_db.latest_call("GetVmStatusCounts")["params"] == ("lnx",)
    assert (body["page"], body["per_page"], body["total"], body["total_pages"]) == (2, 20, 41, 3)
    assert body["counts"] == {"all": 41, "ready": 10, "in-use": 20, "released": 1, "maintenance": 2, "draining": 3,
                              "unreachable": 4, "off": 5, "cleanup": 0}
    first, second, third = body["items"]
    assert "TotalCount" not in first and "SessionsJson" not in first
    assert (first["SessionState"], first["HeartbeatFresh"], first["SettingsCurrent"], first["AgentOutdated"]) == ("disconnected", True, True, False)
    assert (second["SessionState"], second["SettingsCurrent"], second["AgentOutdated"], second["Ready"]) == (None, False, True, True)
    assert (third["SessionState"], third["HeartbeatFresh"], third["AgentOutdated"]) == (None, False, None)


def test_a_signed_in_user_with_no_desktop_shows_as_none(client, fake_db):
    fake_db.fetchall_rows["GetVmsPaged"] = [page_row("lnx-01", SessionsJson="[]")]
    assert client.get("/api/vms?page=1").get_json()["items"][0]["SessionState"] == "none"


def test_an_out_of_range_page_still_reports_the_total(client, fake_db):
    fake_db.fetchall_sequence["GetVmsPaged"] = [[], [page_row("lnx-01", TotalCount=7)]]
    body = client.get("/api/vms?page=9&per_page=5").get_json()
    assert body["items"] == [] and body["total"] == 7 and body["total_pages"] == 2


@pytest.mark.parametrize("query,message", [
    ("status=busy", "status must be one of"),
    ("sort=password", "sort must be one of"),
    ("dir=up", "dir must be asc or desc."),
])
def test_page_parameters_are_validated(client, fake_db, query, message):
    response = client.get(f"/api/vms?{query}")
    assert response.status_code == 400 and message in response.get_json()["error"]
    assert fake_db.calls == []


class Compute:
    def __init__(self, vms):
        self.virtual_machines = self
        self._vms = vms

    def list(self, resource_group):
        return [types.SimpleNamespace(name=name, tags=tags) for name, tags in self._vms]


@pytest.fixture
def azure(app_module, monkeypatch):
    state = {"addresses": {"lnx-new": "10.1.0.5", "lnx-off": "10.1.0.6"}, "power": {"lnx-new": "On", "lnx-off": "Off"}}
    compute = Compute([
        ("lnx-new", {"broker-role": "linux-host"}),
        ("LNX-OFF", {"Broker-Role": "Linux-Host"}),
        ("lnx-nodns", {"broker-role": "linux-host"}),
        ("linux-01", {"broker-role": "linux-host"}),
        ("avd-01", {"broker-role": "avd-host"}),
        ("untagged", None),
    ])
    monkeypatch.setattr(app_module, "VM_SUBSCRIPTION_ID", "sub")
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", "rg")
    monkeypatch.setattr(app_module, "DOMAIN_NAME", "contoso.internal")
    monkeypatch.setattr(app_module, "get_compute_client", lambda: compute)
    monkeypatch.setattr(app_module, "resolve_host_address", lambda name: state["addresses"].get(name.lower()))
    monkeypatch.setattr(app_module, "read_azure_power_states", lambda client, names: (
        [{"hostname": name, "powerState": state["power"][name.lower()]} for name in names if name.lower() in state["power"]], 0))
    return state


def test_candidates_are_tagged_hosts_not_yet_registered(client, fake_db, azure):
    body = client.get("/api/vms/import/candidates").get_json()

    assert [c["Hostname"] for c in body["Candidates"]] == ["lnx-new", "lnx-nodns", "LNX-OFF"]
    new, nodns, off = body["Candidates"]
    assert new == {"Hostname": "lnx-new", "Fqdn": "lnx-new.contoso.internal", "IPAddress": "10.1.0.5", "PowerState": "On",
                   "Importable": True, "Problem": None}
    assert nodns["Importable"] is False and "lnx-nodns.contoso.internal does not resolve" in nodns["Problem"]
    assert off["PowerState"] == "Off" and off["IPAddress"] == "10.1.0.6"
    assert (body["TaggedCount"], body["RegisteredCount"], body["Tag"]) == (4, 1, "broker-role=linux-host")


def test_without_a_domain_name_nothing_can_be_imported(client, fake_db, azure, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "DOMAIN_NAME", None)
    azure["addresses"] = {}
    [first, *_] = client.get("/api/vms/import/candidates").get_json()["Candidates"]
    assert first["Importable"] is False and "DOMAIN_NAME is not set" in first["Problem"]


def test_import_needs_the_azure_settings(client, fake_db, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", None)
    assert client.get("/api/vms/import/candidates").status_code == 409
    assert client.post("/api/vms/import", json={"hostnames": ["lnx-new"]}).status_code == 409


def test_importing_checks_each_host_again(client, fake_db, azure, audit_entries):
    fake_db.fetchone_rows["ImportLinuxHostVm"] = {"Result": "Imported", "VMID": 9, "Hostname": "lnx-new"}

    body = client.post("/api/vms/import", json={"hostnames": ["lnx-new", "lnx-off", "lnx-nodns", "linux-01", "avd-01", "LNX-NEW"]}).get_json()

    assert [(r["Hostname"], r["Result"]) for r in body["Results"]] == [
        ("lnx-new", "Imported"), ("LNX-OFF", "Imported"), ("lnx-nodns", "Unresolved"), ("linux-01", "Exists"), ("avd-01", "NotTagged"),
    ]
    calls = [call["params"] for call in fake_db.calls if call["proc"] == "ImportLinuxHostVm"]
    assert calls == [("lnx-new", "10.1.0.5", "On"), ("LNX-OFF", "10.1.0.6", "Off")]
    assert body["Imported"] == 2 and "Imported 2 of 5 hosts" in body["message"]
    assert "does not resolve" in body["Results"][2]["Problem"]


@pytest.mark.parametrize("payload", [{}, {"hostnames": []}, {"hostnames": ["bad name"]}, {"hostnames": ["h"] * 101}])
def test_import_requests_are_validated(client, fake_db, payload):
    response = client.post("/api/vms/import", json=payload)
    assert response.status_code == 400 and fake_db.calls == []


def test_an_azure_failure_is_reported(client, fake_db, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "VM_SUBSCRIPTION_ID", "sub")
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", "rg")
    monkeypatch.setattr(app_module, "get_compute_client", lambda: 1 / 0)
    response = client.get("/api/vms/import/candidates")
    assert response.status_code == 502 and response.get_json()["error"] == "Unable to list the Linux hosts in Azure."


def test_resolution_stops_at_its_deadline(app_module, monkeypatch):
    import threading
    release = threading.Event()
    monkeypatch.setattr(app_module, "IMPORT_DNS_DEADLINE_SECONDS", 0.2)

    def resolve(name):
        if name == "fast":
            return "10.0.0.1"
        release.wait(2)
        return "10.0.0.2"

    monkeypatch.setattr(app_module, "resolve_host_address", resolve)
    try:
        assert app_module.resolve_host_addresses(["fast", "slow"]) == {"fast": "10.0.0.1", "slow": None}
    finally:
        release.set()
