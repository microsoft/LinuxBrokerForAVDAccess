"""2.9 rolling maintenance: settings and ordering, the routes, and the advance's state machine
tick by tick, with SQL, SSH and Azure replaced by a recorder."""

import json

import pytest


RUN = {"RunID": 7, "Status": "Active", "PatchMode": "Security", "SignOutDeadlineMinutes": None, "WarningMinutes": 15,
       "WarningMessage": None, "MaxFailures": 1, "CanaryReached": False}
LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"


def host_row(**values):
    row = {
        "RunHostID": 11, "RunID": 7, "VMID": 5, "Hostname": "lnx-05", "Position": 1, "State": "Draining", "Version": 3,
        "Attempts": 0, "PatchToken": None, "WasDrained": False, "WasMaintenance": False, "WasPoweredOff": False,
        "RebootRequired": None, "Detail": None, "StepAgeSeconds": 30, "ActionAgeSeconds": None, "AdmittedAgeSeconds": 30,
        "WarningAgeSeconds": None, "SignOutAgeSeconds": None, "RestartAgeSeconds": None, "PatchStartedAtUtc": None,
        "Registered": True, "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "Maintenance", "Username": None,
        "LeaseId": None, "CleanupPending": False, "CleanupUsername": None, "DrainRequested": False,
        "LastCheckoutAgeSeconds": None, "AgentVersion": "1.1.0", "XrdpActive": True, "SessionsJson": "[]",
        "HeartbeatAgeSeconds": 20, "ReconcileIntervalSeconds": 60, "HeartbeatAfterRestart": False, "BootedAfterRestart": False,
    }
    row.update(values)
    return row


def in_use(**values):
    defaults = {"VmStatus": "CheckedOut", "Username": "alice", "LeaseId": LEASE_ID, "DrainRequested": True,
                "SessionsJson": json.dumps([{"username": "alice", "state": "active"}]), "LastCheckoutAgeSeconds": 3600}
    return host_row(**dict(defaults, **values))


class Machine:
    """Stands in for SQL, SSH and Azure around the maintenance handlers."""

    def __init__(self, app_module, monkeypatch):
        self.app = app_module
        self.stored, self.power, self.patch, self.session = [], [], [], []
        self.returned, self.signed_back, self.audits = [], [], []
        self.patch_replies = []
        self.session_reply = {"RESULT": "delivered", "DELIVERED": "1"}
        self.power_error = None
        self.conflict = False
        monkeypatch.setattr(app_module, "store_maintenance_host_state", self.store)
        monkeypatch.setattr(app_module, "maintenance_power", self.do_power)
        monkeypatch.setattr(app_module, "run_patch_host", self.run_patch)
        monkeypatch.setattr(app_module, "run_session_control", self.run_session)
        monkeypatch.setattr(app_module, "return_maintenance_host",
                            lambda host: self.returned.append(host["RunHostID"]) or "ReturnedToService")
        monkeypatch.setattr(app_module, "return_after_signout",
                            lambda vm, user: self.signed_back.append((vm["Hostname"], user)) or "Completed")
        monkeypatch.setattr(app_module, "audit", lambda action, *args, **kwargs: self.audits.append(action))

    def store(self, host, changes):
        self.stored.append(dict(changes))
        if self.conflict:
            return {"Result": "Conflict"}
        moved = bool(changes.get("State")) and changes["State"] != host["State"]
        mark = 1 if changes.get("MarkAction") else 0
        return {"Result": "Updated", "Version": host["Version"] + 1, "State": changes.get("State") or host["State"],
                "Attempts": mark if moved else host["Attempts"] + mark,
                "Detail": changes["Detail"] if "Detail" in changes else host.get("Detail")}

    def do_power(self, host, action):
        self.power.append(action)
        return self.power_error

    def run_patch(self, hostname, arguments):
        self.patch.append(list(arguments))
        reply = self.patch_replies.pop(0) if self.patch_replies else {}
        if isinstance(reply, Exception):
            raise reply
        return reply

    def run_session(self, hostname, arguments, stdin_input=None, timeout=None):
        self.session.append((list(arguments), stdin_input))
        if isinstance(self.session_reply, Exception):
            raise self.session_reply
        return self.session_reply, 0

    def advance(self, host, **run):
        tick = self.app.MaintenanceTick(dict(RUN, **run), deadline=float("inf"))
        self.app.advance_maintenance_host(tick, host)
        return tick

    def states(self):
        return [change["State"] for change in self.stored if change.get("State")]


@pytest.fixture
def machine(app_module, monkeypatch):
    return Machine(app_module, monkeypatch)


# ----------------------------------------------------------------------- draining


def test_a_free_host_moves_straight_on_to_patching(machine):
    host = host_row()
    machine.patch_replies = [{"RESULT": "started", "TOKEN": "lb7-11-1", "STATE": "running"}]

    tick = machine.advance(host)

    assert host["State"] == "Patching" and host["Attempts"] == 1
    assert machine.patch == [["start", "security", "lb7-11-1"]]
    assert host["Detail"] == "Installing security updates."
    assert [action["Action"] for action in tick.actions] == ["patch-start"]


@pytest.mark.parametrize("values,run,expected_state,expected_power", [
    ({"PowerState": "Off", "NetworkStatus": "Unreachable"}, {}, "Starting", ["Start"]),
    ({}, {"PatchMode": "RebootOnly"}, "Verifying", ["Restart"]),
    ({"PowerState": "Off", "NetworkStatus": "Unreachable"}, {"PatchMode": "RebootOnly"}, "Starting", ["Start"]),
])
def test_a_free_host_is_started_or_restarted_as_the_run_needs(machine, values, run, expected_state, expected_power):
    host = host_row(**values)
    machine.advance(host, **run)
    assert host["State"] == expected_state and machine.power == expected_power


def test_without_a_deadline_the_run_waits_for_the_user(machine):
    host = in_use(AdmittedAgeSeconds=99999)
    machine.advance(host)
    assert host["State"] == "Draining" and host["Detail"] == "Waiting for alice to sign out."
    assert machine.session == [] and machine.signed_back == []

    # Writing the same words again would only churn the row.
    machine.advance(host)
    assert len(machine.stored) == 1


def test_a_pending_cleanup_is_waited_for(machine):
    host = host_row(VmStatus="Available", CleanupPending=True, CleanupUsername="bob", DrainRequested=True)
    machine.advance(host, SignOutDeadlineMinutes=30)
    assert host["Detail"] == "Waiting for the broker to remove bob from the host." and machine.session == []


def test_with_a_deadline_the_user_is_warned_then_signed_out(machine):
    run = {"SignOutDeadlineMinutes": 60, "WarningMinutes": 15}
    host = in_use(AdmittedAgeSeconds=40 * 60)
    machine.advance(host, **run)
    assert machine.session == [] and "warned before the 60-minute deadline" in host["Detail"]

    host["AdmittedAgeSeconds"] = 46 * 60
    machine.advance(host, **run)
    [(arguments, text)] = machine.session
    assert arguments == ["message-all"] and "restarts for maintenance in 15 minutes" in text
    assert host["WarningAgeSeconds"] == 0 and "maintenance.user_warned" in machine.audits

    host.update(AdmittedAgeSeconds=61 * 60, WarningAgeSeconds=10 * 60)
    machine.advance(host, **run)
    assert len(machine.session) == 1, "the warning has not been up long enough"

    host.update(WarningAgeSeconds=15 * 60)
    machine.session_reply = {"RESULT": "signed-out"}
    machine.advance(host, **run)
    assert machine.session[-1][0] == ["signout", "alice"]
    assert machine.signed_back == [("lnx-05", "alice")]
    assert host["SignOutAgeSeconds"] == 0 and host["Attempts"] == 1
    assert host["Detail"] == "Signed alice out for maintenance." and "maintenance.user_signed_out" in machine.audits

    # Still assigned a minute later: the sign-out is not repeated until five minutes pass.
    host["SignOutAgeSeconds"] = 60
    machine.advance(host, **run)
    assert len(machine.session) == 2


def test_a_custom_warning_is_shown_as_written(machine):
    host = in_use(AdmittedAgeSeconds=50 * 60)
    machine.advance(host, SignOutDeadlineMinutes=60, WarningMessage="Patching tonight. Please save and leave.")
    assert machine.session[0][1] == "Patching tonight. Please save and leave."


def test_a_user_with_no_session_is_not_waited_for(machine):
    host = in_use(SessionsJson="[]")
    machine.advance(host, SignOutDeadlineMinutes=60)
    assert machine.session == [] and machine.signed_back == [("lnx-05", "alice")]
    assert host["Detail"] == "alice had no session, so the host was returned."


@pytest.mark.parametrize("values", [
    {"SessionsJson": "[]", "LastCheckoutAgeSeconds": 60},
    {"SessionsJson": "[]", "HeartbeatAgeSeconds": 4000},
])
def test_a_user_who_may_be_connecting_is_not_returned_early(machine, values):
    host = in_use(**values)
    machine.advance(host, SignOutDeadlineMinutes=60)
    assert machine.signed_back == []


def test_sign_out_is_retried_and_then_the_host_fails(machine):
    run = {"SignOutDeadlineMinutes": 60}
    host = in_use(AdmittedAgeSeconds=7200, WarningAgeSeconds=3600, SignOutAgeSeconds=400, Attempts=2)
    machine.session_reply = {"RESULT": "signout-incomplete"}
    machine.advance(host, **run)
    assert host["Attempts"] == 3 and "retrying in five minutes" in host["Detail"]

    host["SignOutAgeSeconds"] = 400
    machine.advance(host, **run)
    assert host["State"] == "Failed" and "after 3 attempts" in host["Detail"]
    assert "maintenance.host_failed" in machine.audits


def test_an_agent_that_cannot_warn_fails_the_host(machine, app_module):
    machine.session_reply = app_module.HostAgentOutdated("lnx-05")
    host = in_use(AdmittedAgeSeconds=3500)
    machine.advance(host, SignOutDeadlineMinutes=60)
    assert host["State"] == "Failed" and "older than 1.1.0" in host["Detail"]


def test_a_paused_run_starts_nothing_new(machine):
    host = host_row()
    machine.advance(host, Status="Paused")
    assert host["State"] == "Draining" and machine.stored == [] and machine.patch == []


def test_a_stopping_run_gives_waiting_hosts_back(machine):
    host = in_use()
    tick = machine.advance(host, Status="Stopping")
    assert host["State"] == "Cancelled" and machine.returned == [11]
    assert "returned" in host["Detail"] and tick.actions[0]["Action"] == "returned"


# ----------------------------------------------------------------------- starting


def test_a_started_host_goes_on_to_patching_once_reachable(machine):
    host = host_row(State="Starting", PowerState="On", NetworkStatus="Reachable", ActionAgeSeconds=90)
    machine.patch_replies = [{"RESULT": "started"}]
    machine.advance(host)
    assert machine.states() == ["Patching"] and machine.patch[0][0] == "start"


def test_a_start_counts_as_the_restart_for_a_restart_only_run(machine):
    host = host_row(State="Starting", ActionAgeSeconds=90)
    machine.advance(host, PatchMode="RebootOnly")
    assert host["State"] == "Verifying" and machine.stored[0]["RestartFromAction"] is True


def test_a_start_that_never_arrives_is_repeated_then_fails(machine):
    host = host_row(State="Starting", PowerState="On", NetworkStatus="Unreachable", ActionAgeSeconds=16 * 60, Attempts=1)
    machine.advance(host)
    assert machine.power == ["Start"] and host["Attempts"] == 2

    host.update(ActionAgeSeconds=16 * 60, Attempts=3)
    machine.advance(host)
    assert host["State"] == "Failed" and "did not become reachable" in host["Detail"]


# ----------------------------------------------------------------------- patching


def patching(**values):
    defaults = {"State": "Patching", "ActionAgeSeconds": 120, "Attempts": 1, "PatchToken": "lb7-11-1"}
    return host_row(**dict(defaults, **values))


def test_a_running_patch_is_recorded_once(machine):
    host = patching()
    machine.patch_replies = [{"STATE": "running", "TOKEN": "lb7-11-1"}] * 2
    machine.advance(host)
    assert machine.patch == [["status"]] and machine.stored == [{"MarkPatchStarted": True}]
    machine.advance(host)
    assert len(machine.stored) == 1


def test_a_finished_patch_moves_on_to_the_restart_in_the_same_tick(machine):
    host = patching()
    machine.patch_replies = [{"STATE": "succeeded", "TOKEN": "lb7-11-1", "REBOOT_REQUIRED": "yes", "MANAGER": "dnf"}]
    machine.advance(host)
    assert machine.states() == ["Restarting", "Verifying"]
    assert machine.stored[0]["RebootRequired"] == "yes" and machine.stored[0]["MarkPatchFinished"] is True
    assert machine.power == ["Restart"] and host["RestartAgeSeconds"] == 0
    assert "maintenance.host_patched" in machine.audits


def test_a_failed_patch_fails_the_host_with_the_reason(machine):
    host = patching()
    machine.patch_replies = [{"STATE": "failed", "TOKEN": "lb7-11-1", "EXIT_CODE": "1", "SUMMARY": "Error: Failed to download metadata"}]
    machine.advance(host)
    assert host["State"] == "Failed" and host["Detail"] == "Patching failed (exit 1): Error: Failed to download metadata"


def test_an_interrupted_patch_is_started_again_under_a_new_token(machine):
    host = patching()
    machine.patch_replies = [{"STATE": "interrupted", "TOKEN": "lb7-11-1"}, {"RESULT": "started"}]
    machine.advance(host)
    assert machine.patch == [["status"], ["start", "security", "lb7-11-2"]] and host["Attempts"] == 2

    host.update(Attempts=3, PatchToken="lb7-11-3", ActionAgeSeconds=60)
    machine.patch_replies = [{"STATE": "interrupted", "TOKEN": "lb7-11-3"}]
    machine.advance(host)
    assert host["State"] == "Failed" and host["Detail"] == "The patch run was interrupted, 3 times."


def test_a_worker_that_died_before_starting_the_patch_is_recovered(machine):
    # The attempt was recorded, but the host never heard of it.
    host = patching(ActionAgeSeconds=60)
    machine.patch_replies = [{"STATE": "none", "TOKEN": ""}]
    machine.advance(host)
    assert machine.patch == [["status"]] and machine.stored == []

    host["ActionAgeSeconds"] = 200
    machine.patch_replies = [{"STATE": "succeeded", "TOKEN": "someone-else"}, {"RESULT": "started"}]
    machine.advance(host)
    assert machine.patch[-1] == ["start", "security", "lb7-11-2"]


def test_a_patch_that_runs_too_long_fails(machine, app_module):
    host = patching(ActionAgeSeconds=app_module.MAINTENANCE_PATCH_TIMEOUT_SECONDS + 1, PatchStartedAtUtc="2026-01-01T00:00:00Z")
    machine.patch_replies = [{"STATE": "running", "TOKEN": "lb7-11-1"}]
    machine.advance(host)
    assert host["State"] == "Failed" and "did not finish within 90 minutes" in host["Detail"]


@pytest.mark.parametrize("reply,detail", [
    ({"RESULT": "unsupported"}, "No supported package manager"),
    ("outdated", "older than 1.1.0, which cannot patch it"),
])
def test_a_host_that_cannot_be_patched_fails(machine, app_module, reply, detail):
    host = host_row(State="Patching")
    machine.patch_replies = [app_module.HostAgentOutdated("lnx-05") if reply == "outdated" else reply]
    machine.advance(host)
    assert host["State"] == "Failed" and detail in host["Detail"]


def test_an_unreachable_host_is_retried_on_the_next_tick(machine):
    host = patching()
    machine.patch_replies = [TimeoutError("ssh timed out")]
    machine.advance(host)
    assert host["State"] == "Patching" and "Could not reach lnx-05" in host["Detail"]


def test_a_busy_host_is_waited_for(machine):
    host = host_row(State="Patching")
    machine.patch_replies = [{"RESULT": "busy", "TOKEN": "manual-run"}]
    machine.advance(host)
    assert host["Detail"] == "Another patch run is already going on the host; waiting for it."


# ----------------------------------------------------------------------- restarting and verifying


def test_a_refused_restart_is_retried_after_a_pause(machine):
    host = host_row(State="Restarting")
    machine.power_error = "Azure refused to restart lnx-05."
    machine.advance(host)
    assert host["State"] == "Restarting" and host["Detail"] == "Azure refused to restart lnx-05. Retrying."

    host["ActionAgeSeconds"] = 30
    machine.advance(host)
    assert machine.power == ["Restart"], "too soon to ask again"

    host["ActionAgeSeconds"] = 200
    machine.power_error = None
    machine.advance(host)
    assert machine.power == ["Restart", "Restart"] and host["State"] == "Verifying"


def test_a_restart_already_under_way_is_not_repeated(machine):
    host = host_row(State="Restarting", ActionAgeSeconds=20, NetworkStatus="Unreachable", Attempts=1)
    machine.advance(host)
    assert host["State"] == "Verifying" and machine.power == []


def test_a_host_is_back_only_with_proof_it_restarted(machine):
    host = host_row(State="Verifying", RestartAgeSeconds=120, HeartbeatAfterRestart=True, BootedAfterRestart=False)
    machine.advance(host)
    assert host["State"] == "Verifying" and machine.stored == []

    host.update(BootedAfterRestart=True, XrdpActive=False)
    machine.advance(host)
    assert host["State"] == "Verifying"

    host["XrdpActive"] = True
    machine.advance(host)
    assert host["State"] == "Succeeded" and host["Detail"] == "Patched and restarted."
    assert machine.returned == [11] and "maintenance.host_completed" in machine.audits


def test_a_host_that_was_off_is_stopped_again_before_it_is_returned(machine, monkeypatch, app_module):
    calls = []
    monkeypatch.setattr(app_module, "maintenance_power", lambda host, action: calls.append(("power", action)))
    monkeypatch.setattr(app_module, "return_maintenance_host", lambda host: calls.append(("return",)) or "ReturnedToService")
    host = host_row(State="Verifying", WasPoweredOff=True, HeartbeatAfterRestart=True, BootedAfterRestart=True)

    machine.advance(host, PatchMode="RebootOnly")

    assert calls == [("power", "Stop"), ("return",)]
    assert host["Detail"] == "Restarted. It was powered off again."


def test_a_host_that_does_not_come_back_is_restarted_again_then_fails(machine):
    host = host_row(State="Verifying", RestartAgeSeconds=16 * 60, HeartbeatAfterRestart=True, BootedAfterRestart=False)
    machine.advance(host)
    assert machine.power == ["Restart"] and host["RestartAgeSeconds"] == 0 and host["Attempts"] == 1
    assert "does not show that it restarted" in host["Detail"]

    host.update(RestartAgeSeconds=16 * 60, Attempts=2, NetworkStatus="Unreachable")
    machine.advance(host)
    assert host["State"] == "Failed" and host["Detail"] == "lnx-05 did not come back healthy after restarting: it is not reachable."


def test_a_left_out_host_says_so(machine, monkeypatch, app_module):
    monkeypatch.setattr(app_module, "return_maintenance_host", lambda host: "LeftOutOfService")
    host = host_row(State="Verifying", WasMaintenance=True, HeartbeatAfterRestart=True, BootedAfterRestart=True)
    machine.advance(host)
    assert host["Detail"] == "Patched and restarted. Left out of rotation, as it was before the run."


# ----------------------------------------------------------------------- overlap and removal


def test_a_host_another_advance_moved_is_left_alone(machine):
    machine.conflict = True
    host = host_row()
    machine.advance(host)
    assert host["State"] == "Draining" and machine.patch == [] and len(machine.stored) == 1


def test_a_host_no_longer_registered_fails(machine):
    host = host_row(State="Patching", Registered=False)
    machine.advance(host)
    assert host["State"] == "Failed" and "no longer registered" in host["Detail"] and machine.patch == []


def test_an_unexpected_error_leaves_the_host_for_the_next_tick(machine, monkeypatch, app_module):
    monkeypatch.setattr(app_module, "maintenance_power", lambda host, action: 1 / 0)
    host = host_row(State="Restarting")
    machine.advance(host)
    assert host["State"] == "Restarting"


# ----------------------------------------------------------------------- settings and routes


BODY = {"hostnames": ["lnx-01", "lnx-02"], "patchMode": "security", "batchSize": 2}


@pytest.mark.parametrize("change,message", [
    ({"patchMode": "kernel"}, "patchMode must be Security, All or RebootOnly."),
    ({"hostnames": []}, "hostnames must be a list"),
    ({"hostnames": ["bad name"]}, "hostnames must be a list"),
    ({"batchSize": 0}, "batchSize must be a whole number from 1 to 50."),
    ({"batchSize": "many"}, "batchSize must be a whole number from 1 to 50."),
    ({"minReady": -1}, "minReady must be a whole number from 0 to 1000."),
    ({"signOutDeadlineMinutes": 2}, "signOutDeadlineMinutes must be a whole number from 5 to 1440."),
    ({"signOutDeadlineMinutes": 30, "warningMinutes": 30}, "warningMinutes must be less than signOutDeadlineMinutes."),
    ({"warningMessage": "x" * 501}, "warningMessage must be at most 500 characters."),
    ({"maxFailures": 0}, "maxFailures must be a whole number from 1 to 1000."),
    ({"canaryCount": 51}, "canaryCount must be a whole number from 0 to 50."),
    ({"name": 5}, "name must be text."),
])
def test_run_settings_are_validated(client, fake_db, change, message):
    response = client.post("/api/maintenance/runs/create", json=dict(BODY, **change))
    assert response.status_code == 400 and message in response.get_json()["error"]
    assert fake_db.calls == []


def test_settings_have_defaults(app_module):
    settings = app_module.parse_maintenance_run({"hostnames": ["lnx-01"], "patchMode": "Reboot-Only"})
    assert settings == {
        "name": None, "patchMode": "RebootOnly", "hostnames": ["lnx-01"], "batchSize": 1, "minReady": None,
        "signOutDeadlineMinutes": None, "warningMinutes": 15, "warningMessage": None, "includePoweredOff": False,
        "maxFailures": 1, "canaryCount": 0,
    }


def vm_row(vmid, hostname, **values):
    row = {"VMID": vmid, "Hostname": hostname, "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "Available",
           "Username": None, "LeaseId": None, "CleanupPending": False}
    row.update(values)
    return row


def test_a_run_patches_hosts_that_are_off_then_free_then_in_use(client, fake_db, audit_entries):
    fake_db.fetchall_rows["GetVms"] = [
        vm_row(1, "lnx-busy", VmStatus="CheckedOut", Username="alice"),
        vm_row(2, "lnx-free"),
        vm_row(3, "lnx-off", PowerState="Off"),
        vm_row(4, "lnx-cleanup", CleanupPending=True),
        vm_row(5, "lnx-other"),
    ]
    fake_db.fetchone_rows["CreateMaintenanceRun"] = {"Result": "Created", "RunID": 9, "HostCount": 4}

    response = client.post("/api/maintenance/runs/create", json={
        "hostnames": ["LNX-BUSY", "lnx-free", "lnx-off", "lnx-cleanup", "lnx-free"], "patchMode": "All", "batchSize": 3,
        "minReady": 1, "signOutDeadlineMinutes": 60, "warningMinutes": 10, "includePoweredOff": True, "canaryCount": 1,
        "name": " Tuesday patching ",
    })

    assert response.status_code == 201 and response.get_json()["RunID"] == 9
    params = fake_db.latest_call("CreateMaintenanceRun")["params"]
    assert params[:10] == ("Tuesday patching", "All", 3, 1, 60, 10, None, True, 1, 1)
    assert json.loads(params[10]) == [3, 2, 1, 4]
    assert "within a minute" in response.get_json()["message"]


def test_a_run_needs_registered_hosts_and_no_other_active_run(client, fake_db):
    fake_db.fetchall_rows["GetVms"] = [vm_row(1, "lnx-01"), vm_row(2, "lnx-02")]
    response = client.post("/api/maintenance/runs/create", json=dict(BODY, hostnames=["lnx-01", "ghost"]))
    assert response.status_code == 400 and "ghost" in response.get_json()["error"]
    assert "CreateMaintenanceRun" not in [call["proc"] for call in fake_db.calls]

    fake_db.fetchone_rows["CreateMaintenanceRun"] = {"Result": "RunActive", "RunID": 4}
    response = client.post("/api/maintenance/runs/create", json=BODY)
    assert response.status_code == 409 and "run 4 is still active" in response.get_json()["error"]


def summary_row(**values):
    row = {"RunID": 7, "Name": None, "Status": "Active", "EndStatus": None, "PatchMode": "Security", "BatchSize": 2,
           "MinReadyOverride": None, "SignOutDeadlineMinutes": None, "WarningMinutes": 15, "WarningMessage": None,
           "IncludePoweredOff": False, "MaxFailures": 1, "CanaryCount": 0, "CanaryReached": False, "SurgeRequested": True,
           "WaitReason": "Waiting for a spare ready host.", "StatusReason": None, "CreatedBy": "admin@contoso.com",
           "Total": 3, "Pending": 1, "InProgress": 1, "Succeeded": 1, "Failed": 0, "Skipped": 0, "Cancelled": 0}
    row.update(values)
    return row


def test_runs_are_listed_with_the_active_one(client, fake_db):
    fake_db.fetchall_rows["GetMaintenanceRuns"] = [summary_row(), summary_row(RunID=6, Status="Completed", SurgeRequested=False)]
    fake_db.fetchone_rows["GetMaintenanceRun"] = summary_row(MinReadyInForce=2, ReadyNow=3)

    body = client.get("/api/maintenance/runs").get_json()

    assert [run["RunID"] for run in body["Runs"]] == [7, 6]
    assert body["Active"]["Counts"] == {"Total": 3, "Pending": 1, "InProgress": 1, "Succeeded": 1, "Failed": 0, "Skipped": 0, "Cancelled": 0}
    assert (body["Active"]["SurgeRequested"], body["Active"]["MinReadyInForce"], body["Active"]["ReadyNow"]) == (True, 2, 3)


def test_run_details_list_each_host_without_internal_values(client, fake_db):
    fake_db.fetchone_rows["GetMaintenanceRun"] = summary_row()
    fake_db.fetchall_rows["GetMaintenanceRunHosts"] = [host_row(AgentVersion="1.0.0", PatchToken="lb7-11-1", XrdpActive=None)]

    body = client.get("/api/maintenance/runs/7").get_json()

    [host] = body["Hosts"]
    assert (host["Hostname"], host["State"], host["AgentCanPatch"], host["XrdpActive"]) == ("lnx-05", "Draining", False, None)
    assert "PatchToken" not in host and "LeaseId" not in host and "SessionsJson" not in host

    fake_db.fetchone_rows["GetMaintenanceRun"] = None
    assert client.get("/api/maintenance/runs/8").status_code == 404


@pytest.mark.parametrize("action,result,status,text", [
    ("pause", "Updated", 200, "Paused maintenance run 7"),
    ("resume", "Unchanged", 200, "already resumed"),
    ("cancel", "Updated", 200, "hosts still waiting for their users are returned"),
    ("pause", "InvalidState", 409, "is completed, so it cannot be paused"),
    ("cancel", "NotFound", 404, "was not found"),
])
def test_runs_can_be_paused_resumed_and_cancelled(client, fake_db, action, result, status, text):
    fake_db.fetchone_rows["SetMaintenanceRunStatus"] = summary_row(Result=result, Status="Completed" if result == "InvalidState" else "Active")
    response = client.post(f"/api/maintenance/runs/7/{action}", json={"reason": "  Checking lnx-01  "})
    assert response.status_code == status
    assert text in (response.get_json().get("message") or response.get_json().get("error"))
    assert fake_db.latest_call("SetMaintenanceRunStatus")["params"][:3] == (7, action, "Checking lnx-01")


@pytest.mark.parametrize("claim", [{"Result": "NoRun"}, {"Result": "Busy", "RunID": 7, "Status": "Active"}])
def test_an_advance_with_nothing_to_do_says_why(client, fake_db, claim):
    fake_db.fetchone_rows["BeginMaintenanceTick"] = claim
    body = client.post("/api/maintenance/advance").get_json()
    assert body["Result"] == claim["Result"] and body["Actions"] == []
    assert "ClaimMaintenanceAdmissions" not in [call["proc"] for call in fake_db.calls]


def test_an_advance_admits_hosts_settles_the_run_and_releases_it(client, fake_db, audit_entries):
    fake_db.fetchone_rows["BeginMaintenanceTick"] = summary_row(Result="Claimed", TickToken="token-1")
    fake_db.fetchall_rows["ClaimMaintenanceAdmissions"] = [
        {"RunHostID": 11, "VMID": 5, "Hostname": "lnx-05", "Action": "Admitted", "Detail": None},
        {"RunHostID": 12, "VMID": 6, "Hostname": "lnx-06", "Action": "Skipped", "Detail": "Powered off."},
    ]
    fake_db.fetchone_rows["GetMaintenanceRun"] = summary_row(Pending=0, InProgress=0)
    fake_db.fetchone_rows["SetMaintenanceRunStatus"] = summary_row(Result="Updated", Status="Completed", Pending=0, InProgress=0)

    body = client.post("/api/maintenance/advance").get_json()

    assert body["Result"] == "Advanced" and body["Status"] == "Completed"
    assert [action["Action"] for action in body["Actions"]] == ["admitted", "skipped"]
    assert fake_db.latest_call("SetMaintenanceRunStatus")["params"][:2] == (7, "complete")
    assert fake_db.latest_call("EndMaintenanceTick")["params"] == (7, "token-1")
    actions = [entry["action"] for entry in audit_entries]
    assert {"maintenance.host_admitted", "maintenance.host_skipped", "maintenance.run_completed"} <= set(actions)


def test_too_many_failures_stop_the_run(client, fake_db, audit_entries):
    fake_db.fetchone_rows["BeginMaintenanceTick"] = summary_row(Result="Claimed", TickToken="token-1", Status="Paused")
    fake_db.fetchone_rows["GetMaintenanceRun"] = summary_row(Status="Paused", Failed=2, MaxFailures=2)
    fake_db.fetchone_rows["SetMaintenanceRunStatus"] = summary_row(Result="Updated", Status="Stopping")

    body = client.post("/api/maintenance/advance").get_json()

    call = fake_db.latest_call("SetMaintenanceRunStatus")
    assert call["params"][:3] == (7, "fail", "2 hosts failed, the most this run allows.")
    assert body["Status"] == "Stopping" and "maintenance.run_stopped" in [entry["action"] for entry in audit_entries]


def test_an_advance_releases_the_run_even_when_it_fails(client, fake_db):
    fake_db.fetchone_rows["BeginMaintenanceTick"] = summary_row(Result="Claimed", TickToken="token-1")
    fake_db.raise_on_execute["ClaimMaintenanceAdmissions"] = "deadlock victim"
    assert client.post("/api/maintenance/advance").status_code == 500
    assert fake_db.latest_call("EndMaintenanceTick")["params"] == (7, "token-1")


def test_maintenance_before_the_database_upgrade_answers_404(client, fake_db):
    fake_db.raise_on_execute["BeginMaintenanceTick"] = "(2812, b\"Could not find stored procedure 'BeginMaintenanceTick'.\")"
    assert client.post("/api/maintenance/advance").status_code == 404
    fake_db.raise_on_execute["GetMaintenanceRuns"] = "(2812, b\"Could not find stored procedure 'GetMaintenanceRuns'.\")"
    assert client.get("/api/maintenance/runs").status_code == 404


@pytest.mark.parametrize("path,proc", [("/api/vms/5/undrain", "SetVmDrain"), ("/api/vms/5/maintenance", "SetVmMaintenance")])
def test_a_host_being_patched_cannot_be_returned_to_service(client, fake_db, path, proc):
    fake_db.fetchone_rows[proc] = {"Result": "InvalidState", "VMID": 5, "Hostname": "lnx-05", "VmStatus": "Maintenance",
                                   "Reason": "InMaintenanceRun", "MaintenanceRunID": 7}
    response = client.post(path, json={"enabled": False})
    assert response.status_code == 409
    assert "being patched or restarted by maintenance run 7" in response.get_json()["error"]


def test_failed_maintenance_hosts_need_attention(client, fake_db):
    fake_db.fetchall_rows["GetMaintenanceAttention"] = [
        {"RunID": 7, "RunHostID": 11, "VMID": 5, "Hostname": "lnx-05", "Detail": "Patching failed (exit 1).", "AgeSeconds": 300},
    ]
    [item] = client.get("/api/metrics/attention").get_json()["Items"]
    assert (item["Kind"], item["RunID"], item["Detail"], item["Severity"]) == ("maintenance-failed", 7, "Patching failed (exit 1).", "warning")


def test_the_scaling_preview_shows_a_maintenance_surge(client, fake_db):
    fake_db.fetchone_rows["TriggerScalingLogic"] = {"Action": "PowerOn", "MinVMs": 3, "MaintenanceSurge": True, "CandidatesJson": "[]"}
    assert client.get("/api/scaling/preview").get_json()["Phase"]["MaintenanceSurge"] is True
