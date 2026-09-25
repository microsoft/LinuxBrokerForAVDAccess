"""2.6 trends and unmet demand against the real stored procedures and driver."""

import json


def _checkout(client, username, avdhost="avd-01"):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost})


def test_checkouts_are_counted_by_outcome_and_reported_as_checkout_health(client, db, remote):
    db.add_vm("lnxhost-01")
    assert _checkout(client, "alice").status_code == 200
    assert _checkout(client, "alice").status_code == 200
    assert _checkout(client, "bob").status_code == 409

    events = db.run("SELECT Username, AvdHost, Outcome, DurationMs, Hostname FROM dbo.CheckoutEvents ORDER BY EventID")
    assert [(e["Username"], e["Outcome"], e["Hostname"]) for e in events] == [
        ("alice", "Assigned", "lnxhost-01"), ("alice", "Reused", "lnxhost-01"), ("bob", "NoneAvailable", None),
    ]
    assert all(e["AvdHost"] == "avd-01" and e["DurationMs"] >= 0 for e in events)

    body = client.get("/api/metrics/utilization").get_json()
    stats = body["Checkouts"]
    assert (stats["Total"], stats["Assigned"], stats["Reused"], stats["NoneAvailable"], stats["DeniedLastHour"]) == (3, 1, 1, 1, 1)
    assert stats["DeniedPercent"] == 33.3 and stats["P50Ms"] is not None
    assert len(body["Series"]) == 96
    assert sum(point["Denied"] for point in body["Series"]) == 1 and sum(point["Checkouts"] for point in body["Series"]) == 3


def test_a_failed_provision_is_recorded(client, db, remote):
    db.add_vm("lnxhost-01")
    remote.reply("create", 1, "", "mount failed\n")

    assert _checkout(client, "carol").status_code == 500
    assert db.one("SELECT Outcome, Hostname FROM dbo.CheckoutEvents") == {"Outcome": "ProvisionFailed", "Hostname": "lnxhost-01"}


def test_scaling_runs_feed_the_weekly_series(client, db):
    db.add_vm("lnxhost-01", PowerStateChangedDate=None)
    assert client.post("/api/scaling/trigger", json={}).status_code == 200

    body = client.get("/api/metrics/utilization?hours=168").get_json()

    assert body["BucketMinutes"] == 60 and len(body["Series"]) == 168
    current = body["Series"][-1]
    assert current["Runs"] == 1 and current["PoweredOn"] == 1.0 and current["Serviceable"] == 1.0
    assert (current["MinVMs"], current["MaxVMs"]) == (2, 10)


def test_a_host_start_is_timed_from_the_request_to_the_first_reachable_probe(client, db):
    vm = db.add_vm("lnxhost-01", power="Off", network="Unreachable")
    db.run("EXEC dbo.BeginVmPowerAction @VMID = %s, @Action = 'Start'", (vm["VMID"],))
    db.run("UPDATE dbo.VirtualMachines SET StartRequestedAt = DATEADD(SECOND, -120, SYSUTCDATETIME()) WHERE VMID = %s", (vm["VMID"],))

    response = client.post(f"/api/vms/{vm['VMID']}/network-status", json={"networkstatus": "Reachable"})

    assert response.status_code == 200 and response.get_json()["Changed"] is True
    stats = client.get("/api/metrics/utilization").get_json()["Checkouts"]
    assert stats["HostStarts"] == 1 and 119 <= stats["StartP50Seconds"] <= 125


def test_attention_combines_broker_items_with_host_health(client, db):
    db.add_vm("lnxhost-01", VmStatus="CheckedOut", Username="dave", AvdHost="avd-01",
              LeaseId="8ff6eb09-90ca-4efa-8ea1-695761f950f7")
    db.add_vm("lnxhost-02", network="Unreachable")
    db.run("UPDATE dbo.VirtualMachines SET PowerStateChangedDate = DATEADD(MINUTE, -30, GETDATE()) WHERE Hostname = 'lnxhost-02'")
    db.run("UPDATE dbo.VirtualMachines SET SettingsVersion = (SELECT TOP 1 SettingsVersion FROM dbo.LinuxHostSettings)")
    heartbeat = client.post("/api/hosts/lnxhost-01/heartbeat", data=json.dumps({
        "agentVersion": "1.1.0", "xrdp": {"active": False}, "sessions": [{"username": "dave", "state": "active"}],
    }), content_type="application/json")
    assert heartbeat.status_code == 200, heartbeat.get_json()

    body = client.get("/api/metrics/attention").get_json()

    assert [(item["Kind"], item.get("Hostname"), item.get("Flag")) for item in body["Items"]] == [
        ("no-ready-hosts", None, None), ("unreachable", "lnxhost-02", None), ("health", None, "xrdp-down"),
    ]
    assert body["Items"][1]["AgeSeconds"] >= 29 * 60 and body["Items"][2]["Hostnames"] == ["lnxhost-01"]
    assert body["Summary"]["Critical"] == 1 and body["Incomplete"] is False


def test_the_summary_reports_the_scalers_counts(client, db):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02", VmStatus="CheckedOut", Username="erin", AvdHost="avd-01",
              LeaseId="8ff6eb09-90ca-4efa-8ea1-695761f950f7")
    db.add_vm("lnxhost-03", network="Unreachable", PowerStateChangedDate="2000-01-01")

    body = client.get("/api/vms/summary").get_json()

    assert (body["Serviceable"], body["InUse"], body["Ready"], body["PoweredOn"]) == (2, 1, 1, 3)


def test_the_daily_purge_removes_old_events(client, db, app_module):
    db.run("INSERT INTO dbo.CheckoutEvents (OccurredAt, Username, Outcome) VALUES "
           "(DATEADD(DAY, -200, SYSUTCDATETIME()), 'old', 'Assigned'), (SYSUTCDATETIME(), 'new', 'Assigned')")
    db.run("INSERT INTO dbo.HostStartEvents (Hostname, RequestedAt, ReadyAt, Seconds) VALUES "
           "('h', DATEADD(DAY, -200, SYSUTCDATETIME()), DATEADD(DAY, -200, SYSUTCDATETIME()), 60)")

    body = client.post("/api/audit/purge", json={}).get_json()

    assert body["CheckoutEvents"] == {"CheckoutEventsDeleted": 1, "HostStartEventsDeleted": 1, "MoreRemaining": False,
                                      "RetentionDays": app_module.CHECKOUT_EVENT_RETENTION_DAYS}
    assert [row["Username"] for row in db.run("SELECT Username FROM dbo.CheckoutEvents")] == ["new"]
