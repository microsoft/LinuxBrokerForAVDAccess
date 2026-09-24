"""BFF endpoints added with the Phase 2 foundations: host actions and drain, fleet health,
settings history and the audit log."""

import csv
import io

import pytest

import route_audit
from conftest import API, VMS, post


# ======================================================== host actions


def test_start_forwards_to_the_broker(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms/1/start")

    assert response.status_code == 200
    assert response.get_json()["message"] == "Start requested for linux-host-01."
    assert broker_api.posts[-1]["url"].endswith("/vms/1/start")


def test_stop_forwards_the_mode_and_the_confirmation(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms/2/stop", {"mode": "Deallocate", "confirm": "  linux-host-02 "})

    assert response.status_code == 200
    assert broker_api.posts[-1]["url"].endswith("/vms/2/stop")
    assert broker_api.posts[-1]["json"] == {"confirm": "linux-host-02", "mode": "Deallocate"}

    post(signed_in_client, f"{API}/vms/2/stop", {})
    assert broker_api.posts[-1]["json"] == {}


def test_stop_rejects_an_unknown_mode(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms/2/stop", {"mode": "Hibernate"})

    assert response.status_code == 400
    assert response.get_json()["error"] == "mode must be PowerOff or Deallocate."
    assert broker_api.posts == []


def test_restart_forwards_only_the_confirmation(signed_in_client, broker_api):
    post(signed_in_client, f"{API}/vms/2/restart", {"confirm": "linux-host-02", "mode": "Deallocate"})
    assert broker_api.posts[-1]["json"] == {"confirm": "linux-host-02"}


def test_a_refusal_keeps_the_brokers_status_and_message(signed_in_client, broker_api):
    broker_api.post_replies["/vms/2/stop"] = (409, {
        "error": "linux-host-02 is assigned to alice. Send its hostname as confirm to stop it anyway.",
        "requiresConfirmation": True,
    })

    response = post(signed_in_client, f"{API}/vms/2/stop", {})

    assert response.status_code == 409
    assert "assigned to alice" in response.get_json()["error"]


@pytest.mark.parametrize("path,result", [("drain", "Draining"), ("undrain", "ReturnedToService")])
def test_drain_and_return_to_service_forward_to_the_broker(signed_in_client, broker_api, path, result):
    response = post(signed_in_client, f"{API}/vms/3/{path}")

    assert response.status_code == 200
    assert response.get_json()["Result"] == result
    assert broker_api.posts[-1]["url"].endswith(f"/vms/3/{path}")


def test_power_sync_allows_the_broker_time_to_read_azure(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms/sync")

    assert response.status_code == 200
    assert broker_api.posts[-1]["url"].endswith("/vms/sync")
    assert broker_api.posts[-1]["timeout"] == 60


@pytest.mark.parametrize("path", ["/vms/1/start", "/vms/1/stop", "/vms/1/restart", "/vms/1/drain", "/vms/1/undrain", "/vms/sync"])
def test_host_actions_are_csrf_protected(signed_in_client, broker_api, path):
    response = signed_in_client.post(f"{API}{path}", json={})

    assert response.status_code == 400
    assert broker_api.posts == []


# ======================================================== fleet health and settings history


def test_fleet_health_is_passed_through(signed_in_client, broker_api):
    body = signed_in_client.get(f"{API}/hosts/health").get_json()

    assert body["Summary"]["Healthy"] == 1
    assert [host["Hostname"] for host in body["Hosts"]] == ["linux-host-01", "linux-host-02"]
    assert broker_api.gets[-1]["params"] is None


def test_fleet_health_for_one_host_passes_the_hostname(signed_in_client, broker_api):
    signed_in_client.get(f"{API}/hosts/health?hostname=linux-host-01")
    assert broker_api.gets[-1]["params"] == {"hostname": "linux-host-01"}


def test_settings_history_is_passed_through(signed_in_client, broker_api):
    body = signed_in_client.get(f"{API}/hosts/settings/history").get_json()
    assert body[0]["UpdatedBy"] == "op@contoso.com" and body[0]["IsCurrent"] is True


def test_the_dashboard_carries_the_fleet_health_summary(signed_in_client, broker_api):
    broker_api.vm_summary = dict(broker_api.vm_summary, Draining=2)

    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["stats"]["draining"] == 2
    assert payload["fleetHealth"]["NoHeartbeat"] == 1
    assert payload["fleetHealth"]["ExpectedAgentVersion"] == "1.0.0"
    health_call = next(call for call in broker_api.gets if call["url"].endswith("/hosts/health"))
    assert health_call["params"] == {"summary": "true"}


def test_the_dashboard_survives_an_api_without_fleet_health(signed_in_client, broker_api):
    broker_api.raise_get_paths.add("/hosts/health")

    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["fleetHealth"] is None
    assert payload["stats"] is not None and payload["apiError"] is False


def test_counting_the_vm_list_leaves_draining_hosts_out_of_ready(signed_in_client, broker_api):
    broker_api.summary_status = 500
    VMS[0]["DrainRequested"] = True
    try:
        stats = signed_in_client.get(f"{API}/dashboard").get_json()["stats"]
    finally:
        VMS[0]["DrainRequested"] = False

    assert stats["draining"] == 1 and stats["ready"] == 0


# ============================================================== audit


def test_the_audit_log_passes_filters_and_pages(signed_in_client, broker_api):
    response = signed_in_client.get(
        f"{API}/audit?actor=alice&action=vm.&outcome=failure&from=2026-09-01&to=&page=2&per_page=2&junk=1"
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["page"] == 2 and body["perPage"] == 2 and body["total"] == 3 and body["totalPages"] == 2
    assert [item["AuditId"] for item in body["items"]] == [3]
    assert broker_api.gets[-1]["params"] == {
        "actor": "alice", "action": "vm.", "outcome": "failure", "from": "2026-09-01", "page": 2, "per_page": 2,
    }


def test_the_audit_log_keeps_the_brokers_filter_errors(signed_in_client, monkeypatch):
    import requests
    from conftest import FakeResponse

    monkeypatch.setattr(requests, "get", lambda *a, **k: FakeResponse(
        {"error": "from must be a date (YYYY-MM-DD) or an ISO-8601 UTC time."}, status_code=400))

    response = signed_in_client.get(f"{API}/audit?from=yesterday")

    assert response.status_code == 400
    assert response.get_json()["error"].startswith("from must be a date")


def read_csv(response):
    return list(csv.reader(io.StringIO(response.get_data(as_text=True))))


def test_the_audit_export_is_a_csv_that_cannot_run_formulas(signed_in_client, broker_api):
    broker_api.audit_items = [
        dict(broker_api.audit_items[0], AuditId=1, TargetId="=HYPERLINK(\"http://evil\")", ActorName="+cmd"),
        dict(broker_api.audit_items[0], AuditId=2, TargetId="-2", ActorName="@SUM(A1)", Detail={"error": "x"}),
    ]

    response = signed_in_client.get(f"{API}/audit/export.csv?action=vm.")

    assert response.status_code == 200
    assert response.mimetype == "text/csv"
    assert response.headers["Content-Disposition"].startswith('attachment; filename="linuxbroker-audit-')
    assert response.headers["Cache-Control"] == "no-store"
    rows = read_csv(response)
    assert rows[0][:3] == ["Occurred (UTC)", "Actor", "Actor object ID"]
    assert rows[1][1] == "'+cmd" and rows[1][6] == "'=HYPERLINK(\"http://evil\")"
    assert rows[2][1] == "'@SUM(A1)" and rows[2][6] == "'-2"
    assert rows[2][8] == '{"error": "x"}'
    assert broker_api.gets[-1]["params"]["action"] == "vm."


def test_the_audit_export_pages_through_and_stops_at_the_cap(signed_in_client, broker_api, monkeypatch):
    broker_api.audit_items = [dict(broker_api.audit_items[0], AuditId=i) for i in range(1, 8)]
    monkeypatch.setattr(route_audit, "EXPORT_PAGE_SIZE", 2)

    everything = signed_in_client.get(f"{API}/audit/export.csv")
    assert len(read_csv(everything)) == 8
    assert everything.headers["X-Export-Rows"] == "7"
    assert "X-Export-Truncated" not in everything.headers
    assert [call["params"]["page"] for call in broker_api.gets if call["url"].endswith("/audit")] == [1, 2, 3, 4]

    monkeypatch.setattr(route_audit, "EXPORT_MAX_ROWS", 3)
    capped = signed_in_client.get(f"{API}/audit/export.csv")
    assert len(read_csv(capped)) == 4
    assert capped.headers["X-Export-Truncated"] == "true"


def test_audit_endpoints_require_sign_in(client):
    assert client.get(f"{API}/audit").status_code == 401
    assert client.get(f"{API}/audit/export.csv").status_code == 401
    assert client.get(f"{API}/hosts/health").status_code == 401
