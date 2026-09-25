"""2.6 trends and unmet demand: checkout events, the utilization and attention metrics, the
summary's scaler counts, and the daily purge of old events."""

import json
from datetime import datetime, timezone
from decimal import Decimal

import pytest


LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"
MISSING = "(2812, b\"Could not find stored procedure '{}'.\")"


def procs(fake_db):
    return [call["proc"] for call in fake_db.calls]


def events(fake_db):
    return [call["params"] for call in fake_db.calls if call["proc"] == "RecordCheckoutEvent"]


def checkout_row(**values):
    row = {"VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5", "LeaseId": LEASE_ID, "CheckoutType": "Assigned",
           "ProfileResetRequested": False}
    row.update(values)
    return row


@pytest.fixture
def provisioned(app_module, monkeypatch):
    result = {"ok": True}
    monkeypatch.setattr(app_module, "create_or_update_remote_user", lambda *args: result["ok"])
    monkeypatch.setattr(app_module, "release_vm_assignment", lambda vmid, lease_id: None)
    return result


def checkout(client):
    return client.post("/api/vms/checkout", json={"username": "a.lice", "avdhost": "avd-01"})


# ----------------------------------------------------------------------- checkout events


@pytest.mark.parametrize("row,status,outcome", [
    (checkout_row(), 200, "Assigned"),
    (checkout_row(CheckoutType="Reused"), 200, "Reused"),
    (checkout_row(CheckoutType=None), 200, "Assigned"),
    ({"Message": "No available VM found"}, 409, "NoneAvailable"),
    ({"Message": "Deadlock on db-01", "ErrorNumber": 1205, "Severity": 13, "State": 1}, 500, "Error"),
    (checkout_row(Hostname=None), 500, "Error"),
])
def test_every_checkout_is_recorded_with_its_outcome(client, fake_db, provisioned, row, status, outcome):
    fake_db.fetchall_rows["CheckoutVm"] = [row]

    assert checkout(client).status_code == status

    [params] = events(fake_db)
    username, avdhost, recorded, duration, hostname = params
    assert (username, avdhost, recorded) == ("alice", "avd-01", outcome)
    assert isinstance(duration, int) and duration >= 0
    assert hostname == (row.get("Hostname") if "VMID" in row else None)


def test_a_checkout_with_no_host_at_all_is_unmet_demand(client, fake_db, provisioned):
    fake_db.fetchall_rows["CheckoutVm"] = []
    assert checkout(client).status_code == 409
    assert events(fake_db)[0][2] == "NoneAvailable"


def test_a_host_that_cannot_be_provisioned_is_recorded(client, fake_db, provisioned):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    provisioned["ok"] = False

    assert checkout(client).status_code == 500
    assert events(fake_db) == [("alice", "avd-01", "ProvisionFailed", events(fake_db)[0][3], "lnx-05")]


def test_an_unexpected_failure_is_recorded_as_an_error(client, fake_db, app_module, monkeypatch):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    monkeypatch.setattr(app_module, "create_or_update_remote_user", lambda *args: 1 / 0)

    assert checkout(client).status_code == 500
    assert events(fake_db)[0][2:5:2] == ("Error", "lnx-05")


def test_invalid_requests_and_an_unreachable_database_are_not_recorded(client, fake_db, app_module, monkeypatch):
    assert client.post("/api/vms/checkout", json={"username": "...", "avdhost": "avd-01"}).status_code == 400
    assert client.post("/api/vms/checkout", json={"username": "alice"}).status_code == 400
    assert fake_db.calls == []

    attempts = []
    monkeypatch.setattr(app_module, "get_db_connection", lambda: attempts.append("connect"))
    assert checkout(client).get_json()["error"] == "Database connection failed."
    # Only the checkout tried the database; recording would wait for it again.
    assert attempts == ["connect"]


def test_recording_never_fails_the_checkout_and_a_missing_procedure_is_logged_once(client, fake_db, provisioned, caplog):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    fake_db.raise_on_execute["RecordCheckoutEvent"] = MISSING.format("RecordCheckoutEvent")

    assert checkout(client).status_code == 200
    assert checkout(client).status_code == 200

    assert caplog.text.count("RecordCheckoutEvent is not deployed yet") == 1
    assert procs(fake_db).count("RecordCheckoutEvent") == 2


def test_any_other_recording_failure_is_logged_every_time(client, fake_db, provisioned, caplog):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    fake_db.raise_on_execute["RecordCheckoutEvent"] = "connection reset"

    assert checkout(client).status_code == 200
    assert checkout(client).status_code == 200
    assert caplog.text.count("Could not record the checkout event (Assigned)") == 2


# ----------------------------------------------------------------------- utilization


def test_the_window_ends_with_the_bucket_that_holds_now(app_module):
    now = datetime(2026, 3, 4, 10, 37, 42, tzinfo=timezone.utc)
    assert app_module.utilization_window(24, now) == (datetime(2026, 3, 3, 10, 45), datetime(2026, 3, 4, 10, 45), 15)
    assert app_module.utilization_window(168, now) == (datetime(2026, 2, 25, 11, 0), datetime(2026, 3, 4, 11, 0), 60)


def test_utilization_returns_the_series_and_checkout_health(client, fake_db, app_module, monkeypatch):
    start, end = datetime(2026, 3, 3, 10, 45), datetime(2026, 3, 4, 10, 45)
    monkeypatch.setattr(app_module, "utilization_window", lambda hours: (start, end, 15))
    fake_db.fetchall_rows["GetUtilizationSeries"] = [
        {"BucketStartUtc": "2026-03-03T10:45:00Z", "Runs": 3, "PoweredOn": Decimal("4.0"), "InUse": Decimal("2.3"),
         "Serviceable": Decimal("3.7"), "PeakInUse": 3, "MinVMs": 2, "MaxVMs": 6, "Checkouts": 5, "Denied": 1, "Failed": 0},
        {"BucketStartUtc": "2026-03-03T11:00:00Z", "Runs": 0, "PoweredOn": None, "InUse": None, "Serviceable": None,
         "PeakInUse": None, "MinVMs": None, "MaxVMs": None, "Checkouts": 0, "Denied": 0, "Failed": 0},
    ]
    fake_db.fetchone_rows["GetCheckoutStats"] = {
        "Total": 40, "Assigned": 20, "Reused": 15, "NoneAvailable": 3, "ProvisionFailed": 1, "Errors": 1,
        "P50Ms": 2100, "P95Ms": 8400, "DeniedLastHour": 1, "LastDeniedUtc": "2026-03-04T10:02:11.120Z",
        "HostStarts": 4, "StartP50Seconds": 95, "StartP95Seconds": 180,
    }

    response = client.get("/api/metrics/utilization")

    assert response.status_code == 200
    body = response.get_json()
    assert (body["Hours"], body["BucketMinutes"], body["FromUtc"], body["ToUtc"]) == (24, 15, "2026-03-03T10:45:00Z", "2026-03-04T10:45:00Z")
    assert body["Series"][0] == {"BucketStartUtc": "2026-03-03T10:45:00Z", "Runs": 3, "PoweredOn": 4.0, "InUse": 2.3,
                                 "Serviceable": 3.7, "PeakInUse": 3, "MinVMs": 2, "MaxVMs": 6, "Checkouts": 5, "Denied": 1, "Failed": 0}
    assert body["Series"][1]["PoweredOn"] is None and body["Series"][1]["Runs"] == 0
    assert body["Checkouts"]["DeniedPercent"] == 7.5 and body["Checkouts"]["StartP95Seconds"] == 180
    assert fake_db.latest_call("GetUtilizationSeries")["params"] == (start, end, 15)
    assert fake_db.latest_call("GetCheckoutStats")["params"] == (start, end)


def test_utilization_with_no_checkouts_has_no_denial_rate(client, fake_db):
    fake_db.fetchone_rows["GetCheckoutStats"] = {"Total": 0, "P50Ms": None}
    body = client.get("/api/metrics/utilization?hours=168").get_json()
    assert body["BucketMinutes"] == 60 and body["Series"] == []
    assert body["Checkouts"]["DeniedPercent"] is None and body["Checkouts"]["P50Ms"] is None


@pytest.mark.parametrize("hours", ["12", "abc", "0", "720"])
def test_utilization_only_offers_a_day_or_a_week(client, fake_db, hours):
    response = client.get(f"/api/metrics/utilization?hours={hours}")
    assert response.status_code == 400 and "24, 168" in response.get_json()["error"]
    assert fake_db.calls == []


def test_utilization_before_the_database_upgrade_answers_404(client, fake_db):
    fake_db.raise_on_execute["GetUtilizationSeries"] = MISSING.format("GetUtilizationSeries")
    response = client.get("/api/metrics/utilization")
    assert response.status_code == 404 and "database is upgraded" in response.get_json()["error"]


# ----------------------------------------------------------------------- attention


def health_row(hostname, **values):
    row = {"VMID": 1, "Hostname": hostname, "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "Available",
           "HeartbeatAgeSeconds": 20, "ReconcileIntervalSeconds": 60, "AgentVersion": "1.1.0", "ScriptVersionsJson": None,
           "XrdpActive": True, "NfsReachable": True, "RootDiskFreePct": 50, "CurrentSettingsVersion": 3,
           "AppliedSettingsVersion": 3}
    row.update(values)
    return row


def test_attention_lists_broker_items_and_health_flags_most_severe_first(client, fake_db):
    fake_db.fetchall_rows["GetAttentionItems"] = [
        {"Kind": "unreachable", "VMID": 3, "Hostname": "lnx-03", "Username": None, "AgeSeconds": 1500, "ItemCount": None},
        {"Kind": "denied-checkouts", "VMID": None, "Hostname": None, "Username": None, "AgeSeconds": 300, "ItemCount": 4},
        {"Kind": "never-connected", "VMID": 7, "Hostname": "lnx-07", "Username": "erin", "AgeSeconds": 2700, "ItemCount": None},
    ]
    fake_db.fetchall_rows["GetHostHealth"] = [
        health_row("lnx-01", XrdpActive=False),
        health_row("lnx-02", XrdpActive=False, AgentVersion="1.0.0"),
        health_row("lnx-03", HeartbeatAgeSeconds=4000),
        health_row("lnx-04", NetworkStatus="Unreachable", HeartbeatAgeSeconds=None),
        health_row("lnx-05", PowerState="Off", HeartbeatAgeSeconds=None),
    ]

    response = client.get("/api/metrics/attention")

    assert response.status_code == 200
    body = response.get_json()
    assert [(item["Kind"], item.get("Flag")) for item in body["Items"]] == [
        ("denied-checkouts", None), ("unreachable", None), ("never-connected", None),
        ("health", "xrdp-down"), ("health", "agent-outdated"),
    ]
    xrdp = body["Items"][3]
    assert xrdp == {"Kind": "health", "Flag": "xrdp-down", "Severity": "warning", "Count": 2, "Hostnames": ["lnx-01", "lnx-02"]}
    assert body["Items"][0]["Count"] == 4 and body["Items"][0]["Severity"] == "critical"
    assert body["Items"][2]["Username"] == "erin" and body["Items"][2]["AgeSeconds"] == 2700
    assert body["Summary"] == {"Total": 5, "Critical": 1, "Warning": 3, "Info": 1}
    assert body["Incomplete"] is False
    params = fake_db.latest_call("GetAttentionItems")["params"]
    assert params == (10, 15, 30, 60)


def test_attention_caps_the_hostnames_listed_for_a_flag(client, fake_db):
    fake_db.fetchall_rows["GetHostHealth"] = [health_row(f"lnx-{index:02}", RootDiskFreePct=3) for index in range(14)]
    [item] = client.get("/api/metrics/attention").get_json()["Items"]
    assert item["Flag"] == "low-disk" and item["Count"] == 14 and len(item["Hostnames"]) == 10


def test_attention_before_the_database_upgrade_still_lists_host_health(client, fake_db):
    fake_db.raise_on_execute["GetAttentionItems"] = MISSING.format("GetAttentionItems")
    fake_db.fetchall_rows["GetHostHealth"] = [health_row("lnx-01", NfsReachable=False)]

    body = client.get("/api/metrics/attention").get_json()

    assert body["Incomplete"] is True
    assert [item["Flag"] for item in body["Items"]] == ["nfs-unreachable"]


def test_attention_fails_cleanly_on_other_errors(client, fake_db):
    fake_db.raise_on_execute["GetAttentionItems"] = "timeout on db-prod-01"
    response = client.get("/api/metrics/attention")
    assert response.status_code == 500 and "db-prod-01" not in response.get_data(as_text=True)


# ----------------------------------------------------------------------- summary and purge


def test_the_summary_adds_the_scalers_counts_only_when_the_database_has_them(client, fake_db):
    body = client.get("/api/vms/summary").get_json()
    assert "Serviceable" not in body and "InUse" not in body

    fake_db.fetchone_rows["GetVmSummary"] = dict(fake_db.fetchone_rows["GetVmSummary"], Serviceable=4, InUse=None)
    body = client.get("/api/vms/summary").get_json()
    assert (body["Serviceable"], body["InUse"]) == (4, 0)


def test_the_daily_purge_also_removes_old_checkout_events(client, fake_db, audit_entries, app_module):
    fake_db.fetchone_rows["PurgeAuditLog"] = {"Deleted": 5, "MoreRemaining": False}
    fake_db.fetchall_sequence["PurgeCheckoutEvents"] = [
        [{"RetentionDays": 90, "CheckoutEventsDeleted": 2000, "HostStartEventsDeleted": 40, "MoreRemaining": True}],
        [{"RetentionDays": 90, "CheckoutEventsDeleted": 10, "HostStartEventsDeleted": 0, "MoreRemaining": False}],
    ]

    body = client.post("/api/audit/purge", json={}).get_json()

    assert body["Deleted"] == 5
    assert body["CheckoutEvents"] == {"CheckoutEventsDeleted": 2010, "HostStartEventsDeleted": 40, "MoreRemaining": False,
                                      "RetentionDays": app_module.CHECKOUT_EVENT_RETENTION_DAYS}
    calls = [call for call in fake_db.calls if call["proc"] == "PurgeCheckoutEvents"]
    assert [call["params"] for call in calls] == [(app_module.CHECKOUT_EVENT_RETENTION_DAYS, 2000)] * 2
    detail = json.loads(audit_entries[0]["detailJson"])
    assert (detail["checkoutEventsDeleted"], detail["hostStartEventsDeleted"]) == (2010, 40)


def test_the_event_purge_gets_one_batch_even_when_the_audit_purge_used_the_budget(client, fake_db, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "AUDIT_PURGE_TIME_BUDGET_SECONDS", -1)
    fake_db.fetchone_rows["PurgeCheckoutEvents"] = {"CheckoutEventsDeleted": 2000, "HostStartEventsDeleted": 0, "MoreRemaining": True}

    body = client.post("/api/audit/purge", json={}).get_json()

    assert procs(fake_db).count("PurgeCheckoutEvents") == 1
    assert body["CheckoutEvents"]["MoreRemaining"] is True


@pytest.mark.parametrize("error,key_present", [(MISSING.format("PurgeCheckoutEvents"), False), ("deadlock victim", True)])
def test_an_event_purge_failure_never_fails_the_audit_purge(client, fake_db, audit_entries, error, key_present):
    fake_db.fetchone_rows["PurgeAuditLog"] = {"Deleted": 3, "MoreRemaining": False}
    fake_db.raise_on_execute["PurgeCheckoutEvents"] = error

    response = client.post("/api/audit/purge", json={})

    assert response.status_code == 200 and response.get_json()["Deleted"] == 3
    assert ("CheckoutEvents" in response.get_json()) is key_present
    detail = json.loads(audit_entries[0]["detailJson"])
    assert detail.get("eventsFailed", False) is key_present
