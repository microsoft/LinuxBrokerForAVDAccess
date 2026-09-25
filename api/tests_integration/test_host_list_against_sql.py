"""2.7 the host list and import against the real stored procedures and driver."""

import json
import types

import pytest


def test_the_host_list_pages_filters_and_counts_in_sql(client, db):
    for name in ("lnx-01", "lnx-02", "lnx-03"):
        db.add_vm(name)
    db.add_vm("lnx-busy", VmStatus="CheckedOut", Username="alice", AvdHost="avd-01",
              LeaseId="8ff6eb09-90ca-4efa-8ea1-695761f950f7")
    db.add_vm("lnx-off", power="Off", network="Unreachable")
    heartbeat = client.post("/api/hosts/lnx-busy/heartbeat", data=json.dumps({
        "agentVersion": "1.1.0", "sessions": [{"username": "alice", "state": "active"}],
        "os": {"id": "ubuntu", "version": "24.04", "name": "Ubuntu 24.04"},
    }), content_type="application/json")
    assert heartbeat.status_code == 200, heartbeat.get_json()

    body = client.get("/api/vms?page=1&per_page=2&status=ready&sort=hostname&dir=desc").get_json()
    assert [item["Hostname"] for item in body["items"]] == ["lnx-03", "lnx-02"]
    assert (body["total"], body["total_pages"]) == (3, 2)
    assert body["counts"]["all"] == 5 and body["counts"]["ready"] == 3 and body["counts"]["off"] == 1

    busy = client.get("/api/vms?q=ubuntu").get_json()["items"]
    assert [item["Hostname"] for item in busy] == ["lnx-busy"]
    assert (busy[0]["SessionState"], busy[0]["OsName"], busy[0]["HeartbeatFresh"]) == ("active", "Ubuntu 24.04", True)

    assert isinstance(client.get("/api/vms").get_json(), list)


class Compute:
    def __init__(self, names):
        self.virtual_machines = self
        self.names = names

    def list(self, resource_group):
        return [types.SimpleNamespace(name=name, tags={"broker-role": "linux-host"}) for name in self.names]

    def instance_view(self, resource_group, name):
        return types.SimpleNamespace(statuses=[types.SimpleNamespace(code="PowerState/running")])


@pytest.fixture
def azure(app_module, monkeypatch):
    compute = Compute(["lnx-new", "lnx-nodns", "lnx-01"])
    monkeypatch.setattr(app_module, "VM_SUBSCRIPTION_ID", "sub")
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", "rg")
    monkeypatch.setattr(app_module, "DOMAIN_NAME", "contoso.internal")
    monkeypatch.setattr(app_module, "get_compute_client", lambda: compute)
    monkeypatch.setattr(app_module, "resolve_host_address", lambda name: {"lnx-new": "10.1.0.5", "lnx-01": "10.0.0.4"}.get(name))
    return compute


def test_a_tagged_host_is_imported_unreachable_until_probed(client, db, azure):
    db.add_vm("lnx-01")

    candidates = client.get("/api/vms/import/candidates").get_json()["Candidates"]
    assert [(c["Hostname"], c["Importable"], c["PowerState"]) for c in candidates] == [
        ("lnx-new", True, "On"), ("lnx-nodns", False, "On"),
    ]

    body = client.post("/api/vms/import", json={"hostnames": ["lnx-new", "lnx-nodns"]}).get_json()
    assert [(r["Hostname"], r["Result"]) for r in body["Results"]] == [("lnx-new", "Imported"), ("lnx-nodns", "Unresolved")]
    vm = db.vm("lnx-new")
    assert (vm["PowerState"], vm["NetworkStatus"], vm["VmStatus"], vm["IPAddress"]) == ("On", "Unreachable", "Available", "10.1.0.5")

    assert [c["Hostname"] for c in client.get("/api/vms/import/candidates").get_json()["Candidates"]] == ["lnx-nodns"]
    again = client.post("/api/vms/import", json={"hostnames": ["lnx-new"]}).get_json()
    assert again["Results"][0]["Result"] == "Exists"
