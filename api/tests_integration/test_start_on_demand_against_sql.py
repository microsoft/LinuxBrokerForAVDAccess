"""4.1 start on demand and scale to zero against the real stored procedures and driver."""

import json
import types

import pytest


RULE = {"minvms": 2, "maxvms": 6, "scaleupratio": 70, "scaleupincrement": 1, "scaledownratio": 30, "scaledownincrement": 1}
EVERY_DAY = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class Compute:
    def __init__(self, states=None, fail=()):
        self.operations = []
        self.states = states or {}
        self.fail = set(fail)
        compute = self

        class VirtualMachines:
            def _operate(self, operation, name):
                if operation in compute.fail:
                    raise RuntimeError("refused")
                compute.operations.append((operation, name))

            def instance_view(self, resource_group, name):
                return types.SimpleNamespace(statuses=[types.SimpleNamespace(code=compute.states.get(name, "PowerState/running"))])

            def begin_start(self, resource_group, name):
                self._operate("start", name)

            def begin_power_off(self, resource_group, name):
                self._operate("power_off", name)

            def begin_deallocate(self, resource_group, name):
                self._operate("deallocate", name)

        self.virtual_machines = VirtualMachines()


@pytest.fixture
def compute(app_module, monkeypatch):
    fake = Compute()
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)
    return fake


@pytest.fixture
def probes(app_module, monkeypatch):
    """The hosts that answer the start on demand probe, by IP address."""
    answering = set()
    monkeypatch.setattr(app_module, "probe_ssh", lambda ip: ip in answering)
    return answering


def _checkout(client, username, avdhost="avd-01", **extra):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost, **extra})


def _events(db):
    return [(row["Username"], row["Outcome"], row["Hostname"], row["ClientVersion"])
            for row in db.run("SELECT Username, Outcome, Hostname, ClientVersion FROM dbo.CheckoutEvents ORDER BY EventID")]


def _audits(db, action):
    return db.run("SELECT TargetId, Outcome, DetailJson FROM dbo.AuditLog WHERE Action = %s ORDER BY AuditId", (action,))


def test_a_checkout_that_finds_no_ready_host_starts_one_and_is_told_to_wait(client, db, remote, compute, probes):
    db.add_vm("lnxhost-01", power="Off", network="Unreachable")

    response = _checkout(client, "alice", clientVersion="2.0.0")

    assert response.status_code == 202, response.get_json()
    body = response.get_json()
    # With no start history the procedure expects a start to take 60 seconds.
    assert body == {"status": "Starting", "reason": "Started", "retryAfterSeconds": 60,
                    "message": "A Linux host is starting for you. Ask again in 60 seconds."}
    assert response.headers["Retry-After"] == "60"
    assert compute.operations == [("start", "lnxhost-01")]
    vm = db.vm("lnxhost-01")
    assert (vm["PowerState"], vm["NetworkStatus"], vm["VmStatus"], vm["Username"]) == ("On", "Unreachable", "Available", None)
    assert vm["StartRequestedAt"] is not None

    log = db.one("SELECT TOP 1 * FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert log["ActionTaken"] == "Start On Demand" and log["VMsPoweredOn"] == 1
    assert "alice" in log["Notes"] and "avd-01" in log["Notes"]
    assert _events(db) == [("alice", "Starting", "lnxhost-01", "2.0.0")]
    [entry] = _audits(db, "vm.start_on_demand")
    detail = json.loads(entry["DetailJson"])
    assert (entry["TargetId"], entry["Outcome"]) == ("lnxhost-01", "success")
    assert (detail["username"], detail["avdhost"], detail["clientVersion"], detail["activityId"]) == (
        "alice", "avd-01", "2.0.0", log["ActivityID"])
    assert remote.calls == [], "no user is created until a host is ready"


def test_the_waiting_user_is_given_the_host_as_soon_as_it_answers(client, db, remote, compute, probes):
    db.add_vm("lnxhost-01", power="Off", network="Unreachable")
    assert _checkout(client, "alice", clientVersion="2.0.0").status_code == 202
    # The host was asked to start 90 seconds ago, and has not answered yet.
    db.run("UPDATE dbo.VirtualMachines SET StartRequestedAt = DATEADD(SECOND, -90, SYSUTCDATETIME()), "
           "PowerStateChangedDate = DATEADD(SECOND, -90, GETDATE())")
    db.run("UPDATE dbo.CheckoutEvents SET OccurredAt = DATEADD(SECOND, -90, OccurredAt)")

    still_starting = _checkout(client, "alice", clientVersion="2.0.0")
    assert still_starting.status_code == 202, still_starting.get_json()
    assert still_starting.get_json()["reason"] == "AlreadyStarting"
    assert still_starting.get_json()["retryAfterSeconds"] == 30, "a start expected in 60 seconds is already overdue"
    assert compute.operations == [("start", "lnxhost-01")], "a user already waiting does not start a second host"

    probes.add("10.0.0.4")
    ready = _checkout(client, "alice", clientVersion="2.0.0")

    assert ready.status_code == 200, ready.get_json()
    assert ready.get_json()["Hostname"] == "lnxhost-01"
    vm = db.vm("lnxhost-01")
    assert (vm["NetworkStatus"], vm["VmStatus"], vm["Username"]) == ("Reachable", "CheckedOut", "alice")
    assert [kind for _, kind in remote.calls] == ["create"]
    start = db.one("SELECT Hostname, Seconds FROM dbo.HostStartEvents")
    assert start["Hostname"] == "lnxhost-01" and 85 <= start["Seconds"] <= 120

    stats = client.get("/api/metrics/utilization").get_json()["Checkouts"]
    assert (stats["Total"], stats["Assigned"], stats["Starting"]) == (1, 1, 2)
    assert (stats["Waits"], stats["WaitsServed"], stats["WaitingNow"]) == (1, 1, 0)
    assert 85 <= stats["WaitP50Seconds"] <= 120
    series = client.get("/api/metrics/utilization").get_json()["Series"]
    assert sum(point["Waited"] for point in series) == 1


def test_starts_for_waiting_users_stop_at_the_pending_limit(client, db, remote, compute, probes):
    for index in range(1, 4):
        db.add_vm(f"lnxhost-0{index}", power="Off", network="Unreachable")

    first = _checkout(client, "alice")
    second = _checkout(client, "bob")
    third = _checkout(client, "carol")

    assert [r.get_json()["reason"] for r in (first, second, third)] == ["Started", "Started", "AlreadyStarting"]
    assert compute.operations == [("start", "lnxhost-01"), ("start", "lnxhost-02")]
    assert db.vm("lnxhost-03")["PowerState"] == "Off"
    assert client.get("/api/metrics/utilization").get_json()["Checkouts"]["WaitingNow"] == 3

    preview = client.get("/api/scaling/preview").get_json()
    assert preview["Counts"]["Waiting"] == 3 and preview["StartOnDemandEnabled"] is True


def test_a_refused_start_puts_the_host_back_off_and_refuses_the_checkout(app_module, client, db, remote, monkeypatch):
    db.add_vm("lnxhost-01", power="Off", network="Unreachable")
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: Compute(fail={"start"}))

    response = _checkout(client, "alice", clientVersion="2.0.0")

    assert response.status_code == 409, response.get_json()
    vm = db.vm("lnxhost-01")
    assert (vm["PowerState"], vm["NetworkStatus"]) == ("Off", "Unreachable")
    log = db.one("SELECT TOP 1 Notes FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert "Starting lnxhost-01 failed, so it was recorded as off again." in log["Notes"]
    [entry] = _audits(db, "vm.start_on_demand")
    assert entry["Outcome"] == "failure"
    assert json.loads(entry["DetailJson"])["error"] == "The Azure start operation could not be requested."
    assert _events(db) == [("alice", "NoneAvailable", None, "2.0.0")]


def test_the_policy_update_sets_start_on_demand_with_the_time_zone_or_not_at_all(app_module, client, db, monkeypatch):
    updated = client.post("/api/scaling/policy/update", json={"startondemandenabled": False, "maxpendingstarts": "5"})
    assert updated.status_code == 200, updated.get_json()
    assert updated.get_json() == {
        "Result": "Updated", "StartOnDemandEnabled": False, "MaxPendingStarts": 5, "ZeroMinimumCount": 0,
        "message": "Start on demand is off. A user who finds no ready host is refused.",
    }
    policy = client.get("/api/scaling/policy").get_json()
    assert (policy["StartOnDemandEnabled"], policy["MaxPendingStarts"], policy["ZeroMinimumCount"]) == (False, 5, 0)

    again = client.post("/api/scaling/policy/update", json={"startondemandenabled": False}).get_json()
    assert again["Result"] == "Unchanged"

    both = client.post("/api/scaling/policy/update", json={"timezone": "Tokyo Standard Time", "startondemandenabled": True})
    assert both.status_code == 200 and both.get_json()["Result"] == "Updated"
    assert both.get_json()["message"] == ("Schedules are now read in Tokyo Standard Time. "
                                          "Start on demand is on. Up to 5 hosts may start at once for waiting users.")

    refused = client.post("/api/scaling/policy/update", json={"timezone": "Nowhere", "startondemandenabled": False})
    assert refused.status_code == 400
    assert client.post("/api/scaling/policy/update", json={"maxpendingstarts": 21}).status_code == 400
    policy = client.get("/api/scaling/policy").get_json()
    assert (policy["TimeZone"], policy["StartOnDemandEnabled"], policy["MaxPendingStarts"]) == ("Tokyo Standard Time", True, 5)

    # The database refusing the start on demand half rolls back the time zone set before it.
    monkeypatch.setattr(app_module, "_policy_update_fields", lambda body: {"timezone": "UTC", "maxpendingstarts": 99})
    invalid = client.post("/api/scaling/policy/update", json={})
    assert invalid.status_code == 400 and invalid.get_json()["error"] == "maxpendingstarts must be between 1 and 20."
    assert client.get("/api/scaling/policy").get_json()["TimeZone"] == "Tokyo Standard Time"


def test_a_minimum_of_zero_needs_start_on_demand(client, db, compute):
    rule_id = client.get("/api/scaling/rules").get_json()[0]["RuleID"]
    assert client.post(f"/api/scaling/rules/{rule_id}/update", json={"minvms": 0}).status_code == 200
    assert client.get("/api/scaling/policy").get_json()["ZeroMinimumCount"] == 1

    off = client.post("/api/scaling/policy/update", json={"startondemandenabled": False}).get_json()
    assert off["message"] == ("Start on demand is off. 1 scaling rule or window has a minimum of 0, "
                              "so scaling keeps one host running for them.")
    preview = client.get("/api/scaling/preview").get_json()
    assert preview["Phase"]["MinVMs"] == 1 and preview["StartOnDemandEnabled"] is False

    window = {"name": "Nights", "days": EVERY_DAY, "start": "20:00", "end": "06:00", **RULE, "minvms": 0}
    refused = client.post("/api/scaling/schedules/create", json=window)
    assert refused.status_code == 400 and refused.get_json()["error"] == "minvms can be 0 only while start on demand is on."
    refused_rule = client.post(f"/api/scaling/rules/{rule_id}/update", json={"minvms": 0, "maxvms": 8})
    assert refused_rule.status_code == 400

    assert client.post("/api/scaling/policy/update", json={"startondemandenabled": True}).status_code == 200
    assert client.post("/api/scaling/schedules/create", json=window).status_code == 201
    assert client.get("/api/scaling/policy").get_json()["ZeroMinimumCount"] == 2


def test_scale_to_zero_stops_the_last_idle_host_and_the_next_user_starts_it(client, db, remote, compute, probes):
    db.add_vm("lnxhost-01", PowerStateChangedDate="2000-01-01")
    rule_id = client.get("/api/scaling/rules").get_json()[0]["RuleID"]
    assert client.post(f"/api/scaling/rules/{rule_id}/update", json={"minvms": 0}).status_code == 200

    scaled = client.post("/api/scaling/trigger", json={})

    assert scaled.status_code == 200, scaled.get_json()
    assert scaled.get_json()["PoweredOffVMs"] == ["lnxhost-01"]
    assert compute.operations == [("power_off", "lnxhost-01")]
    assert db.vm("lnxhost-01")["PowerState"] == "Off"

    compute.states["lnxhost-01"] = "PowerState/stopped"
    response = _checkout(client, "alice")
    assert response.status_code == 202 and response.get_json()["reason"] == "Started"
    assert compute.operations[-1] == ("start", "lnxhost-01")

    # While alice waits, scaling keeps the host she is waiting for.
    compute.states["lnxhost-01"] = "PowerState/running"
    again = client.post("/api/scaling/trigger", json={})
    assert again.status_code == 200 and again.get_json()["PoweredOffVMs"] == []
    assert db.vm("lnxhost-01")["PowerState"] == "On"


def test_the_policy_reports_which_broker_script_each_avd_host_runs(client, db, remote):
    db.run("UPDATE dbo.ScalingPolicy SET StartOnDemandEnabled = 0")
    assert _checkout(client, "alice", "avd-01", clientVersion="2.0.0").status_code == 409
    assert _checkout(client, "bob", "avd-02").status_code == 409
    assert _checkout(client, "carol", "avd-03", clientVersion="1.9.0").status_code == 409
    assert _checkout(client, "dave", "avd-04", clientVersion="not a version!").status_code == 409

    scripts = client.get("/api/scaling/policy").get_json()["AvdHostScripts"]

    assert scripts == {
        "Seen": 4, "Outdated": 2, "OutdatedHostnames": ["avd-02", "avd-04"],
        "Versions": [{"ClientVersion": "1.9.0", "AvdHosts": 1, "Current": False},
                     {"ClientVersion": "2.0.0", "AvdHosts": 1, "Current": True}],
        "CurrentVersion": "2.0.0",
    }

    # Only each AVD host's latest checkout counts, so an updated host stops being outdated.
    assert _checkout(client, "bob", "avd-02", clientVersion="2.0.0").status_code == 409
    scripts = client.get("/api/scaling/policy").get_json()["AvdHostScripts"]
    assert scripts["Outdated"] == 1 and scripts["OutdatedHostnames"] == ["avd-04"]
    assert {"ClientVersion": "2.0.0", "AvdHosts": 2, "Current": True} in scripts["Versions"]
