"""Contract tests for 2.3 sessions and users (088-100): assignment dates and checkout types,
the Sessions reader, user search and details, host history, and profile resets."""

import json
import time

from conftest import add_vm, exec_sql, one, rows


def checkout(conn, username, avdhost="avd-01"):
    result = exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", (username, avdhost))
    return result[0] if result else None


def add_user(conn, username, uid):
    exec_sql(conn, "INSERT INTO dbo.VmUsers (uid, username) VALUES (%s, %s)", (uid, username))


def heartbeat(conn, hostname, sessions, age_seconds=None):
    document = {"agentVersion": "1.1.0", "sessions": sessions}
    result = exec_sql(conn, "EXEC dbo.RecordHostHeartbeat @Hostname=%s, @HeartbeatJson=%s", (hostname, json.dumps(document)))
    assert result[0]["Result"] == "Recorded"
    if age_seconds is not None:
        exec_sql(
            conn,
            "UPDATE dbo.HostHeartbeats SET ReceivedAt=DATEADD(SECOND, -%d, SYSUTCDATETIME()) WHERE Hostname=%%s" % age_seconds,
            (hostname,),
        )


def session(username, state="active", idle=None, disconnected_since=None):
    return {"username": username, "state": state, "sessionStart": 1790000000,
            "disconnectedSince": disconnected_since, "idleSeconds": idle}


def sessions_by_key(conn):
    return {(r["Hostname"], r["Username"]): r for r in exec_sql(conn, "EXEC dbo.GetSessions")}


def vm_row(conn, vmid):
    return one(conn, "SELECT * FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))


# ------------------------------------------------------------------ checkout additions


def test_checkout_reports_its_type_and_stamps_assignment_dates(conn):
    vmid = add_vm(conn, "co-1")

    first = checkout(conn, "alice")
    assert first["VMID"] == vmid and first["CheckoutType"] == "Assigned"
    assert first["ProfileResetRequested"] is False
    stamped = vm_row(conn, vmid)
    assert stamped["AssignedDate"] is not None and stamped["LastCheckoutDate"] is not None

    exec_sql(conn, "UPDATE dbo.VirtualMachines SET AssignedDate=DATEADD(HOUR, -2, GETDATE()), "
                   "LastCheckoutDate=DATEADD(HOUR, -2, GETDATE()), VmStatus='Released', ReleasedDate=GETDATE() WHERE VMID=%s", (vmid,))
    again = checkout(conn, "alice")
    assert again["VMID"] == vmid and again["CheckoutType"] == "Reused"
    reconnected = vm_row(conn, vmid)
    # A reconnect keeps when the assignment began and records the new checkout.
    assert (reconnected["LastCheckoutDate"] - reconnected["AssignedDate"]).total_seconds() > 3600
    assert reconnected["ReleasedDate"] is None and reconnected["VmStatus"] == "CheckedOut"


def test_checkout_flags_a_requested_profile_reset(conn):
    add_vm(conn, "co-reset")
    add_user(conn, "bob", 5001)
    assert exec_sql(conn, "EXEC dbo.RequestProfileReset @Username=%s, @RequestedBy=%s", ("bob", "admin@contoso.com"))[0]["Result"] == "Requested"

    assert checkout(conn, "bob")["ProfileResetRequested"] is True


def test_checkout_without_a_host_still_answers_with_a_message(conn):
    assert checkout(conn, "nobody-free") == {"Message": "No available VM found"}


# ---------------------------------------------------------------------------- sessions


def test_sessions_join_assignments_with_reported_sessions(conn):
    active_vm = add_vm(conn, "ses-active", status="CheckedOut", username="alice", lease="11111111-1111-1111-1111-111111111111")
    add_vm(conn, "ses-released", status="Released", username="bob", lease="22222222-2222-2222-2222-222222222222", released_seconds=100)
    add_vm(conn, "ses-cleanup", status="Available", username=None, cleanup=True)
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupUsername='carol' WHERE Hostname='ses-cleanup'")
    add_vm(conn, "ses-quiet", status="CheckedOut", username="dave", lease="33333333-3333-3333-3333-333333333333")
    add_vm(conn, "ses-free")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET AssignedDate=DATEADD(MINUTE, -45, GETDATE()) WHERE Hostname='ses-quiet'")

    heartbeat(conn, "ses-active", [session("alice", idle=30)])
    heartbeat(conn, "ses-released", [])
    heartbeat(conn, "ses-quiet", [])
    heartbeat(conn, "ses-free", [session("mallory", state="disconnected", disconnected_since=int(time.time()) - 300)], age_seconds=30)

    found = sessions_by_key(conn)
    assert set(found) == {("ses-active", "alice"), ("ses-released", "bob"), ("ses-cleanup", "carol"),
                          ("ses-quiet", "dave"), ("ses-free", "mallory")}

    alice = found[("ses-active", "alice")]
    assert alice["VMID"] == active_vm and alice["HasAssignment"] is True and alice["BrokerTracked"] is True
    assert alice["SessionState"] == "active" and alice["IdleSeconds"] == 30
    assert 0 <= alice["HeartbeatAgeSeconds"] < 30
    assert alice["GracePeriodSeconds"] == 1200 and alice["ReconcileIntervalSeconds"] == 60

    bob = found[("ses-released", "bob")]
    assert bob["SessionState"] is None and bob["VmStatus"] == "Released"
    assert 1080 <= bob["GraceRemainingSeconds"] <= 1101

    carol = found[("ses-cleanup", "carol")]
    assert carol["CleanupPending"] is True and carol["HasAssignment"] is False and carol["BrokerTracked"] is True

    dave = found[("ses-quiet", "dave")]
    assert dave["SessionState"] is None and 2690 <= dave["AssignedForSeconds"] <= 2720

    mallory = found[("ses-free", "mallory")]
    assert mallory["HasAssignment"] is False and mallory["BrokerTracked"] is False
    assert mallory["VmStatus"] == "Available" and mallory["SessionState"] == "disconnected"
    assert 280 <= mallory["DisconnectedForSeconds"] <= 360 and 25 <= mallory["HeartbeatAgeSeconds"] <= 60


def test_sessions_are_empty_without_assignments_or_heartbeats(conn):
    add_vm(conn, "ses-none")
    assert exec_sql(conn, "EXEC dbo.GetSessions") == []


# ------------------------------------------------------------------------------- users


def test_user_search_ranks_exact_then_prefix_then_contains(conn):
    for uid, name in enumerate(("johnsmith", "john", "bigjohn", "alice"), start=6000):
        add_user(conn, name, uid)
    add_vm(conn, "usr-1", status="CheckedOut", username="john", lease="44444444-4444-4444-4444-444444444444")

    found = exec_sql(conn, "EXEC dbo.SearchUsers @Query=%s", ("john",))
    assert [r["Username"] for r in found] == ["john", "johnsmith", "bigjohn"]
    assert found[0]["CurrentHostname"] == "usr-1" and found[0]["CurrentVmStatus"] == "CheckedOut"
    assert found[1]["CurrentHostname"] is None and found[1]["ProfileResetPending"] is False
    assert len(exec_sql(conn, "EXEC dbo.SearchUsers @Query=%s, @Limit=%s", (None, 2))) == 2
    assert exec_sql(conn, "EXEC dbo.SearchUsers @Query=%s", ("%",)) == []


def test_user_details_list_assignments_and_cleanups(conn):
    add_user(conn, "erin", 7001)
    add_vm(conn, "det-1", status="CheckedOut", username="erin", lease="55555555-5555-5555-5555-555555555555")
    add_vm(conn, "det-2", status="Available", cleanup=True)
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupUsername='erin' WHERE Hostname='det-2'")
    add_vm(conn, "det-3", status="CheckedOut", username="frank", lease="66666666-6666-6666-6666-666666666666")

    details = exec_sql(conn, "EXEC dbo.GetUserDetails @Username=%s", ("erin",))[0]
    assert details["Uid"] == 7001 and details["ProfileResetRequestedAtUtc"] is None
    assignments = {a["Hostname"]: a for a in json.loads(details["AssignmentsJson"])}
    assert set(assignments) == {"det-1", "det-2"}
    assert assignments["det-1"]["CleanupPending"] is False and assignments["det-2"]["CleanupPending"] is True

    # frank has an assignment but no VmUsers row: still found, without a uid.
    frank = exec_sql(conn, "EXEC dbo.GetUserDetails @Username=%s", ("frank",))[0]
    assert frank["Uid"] is None and len(json.loads(frank["AssignmentsJson"])) == 1
    assert exec_sql(conn, "EXEC dbo.GetUserDetails @Username=%s", ("nobody",)) == []


def test_user_host_history_comes_from_the_temporal_table(conn):
    first = add_vm(conn, "hist-1")
    second = add_vm(conn, "hist-2", power="Off", net="Unreachable")

    checkout(conn, "gina")
    returned = exec_sql(conn, "EXEC dbo.ReturnVm @VMID=%s", (first,))
    assert returned and returned[0].get("ReturnedUsername") == "gina"
    exec_sql(conn, "EXEC dbo.CompleteVmCleanup @VMID=%s, @LeaseId=%s, @Username=%s",
             (first, returned[0]["ReturnedLeaseId"], "gina"))
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET PowerState='On', NetworkStatus='Reachable' WHERE VMID=%s", (second,))
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET NetworkStatus='Unreachable' WHERE VMID=%s", (first,))
    assert checkout(conn, "gina")["VMID"] == second

    history = exec_sql(conn, "EXEC dbo.GetUserHostHistory @Username=%s", ("gina",))
    assert [r["Hostname"] for r in history] == ["hist-2", "hist-1"]
    assert history[0]["IsCurrent"] is True and history[1]["IsCurrent"] is False
    assert history[1]["Assignments"] == 1
    assert history[0]["FirstSeenUtc"].endswith("Z") and history[0]["LastSeenUtc"].endswith("Z")
    assert exec_sql(conn, "EXEC dbo.GetUserHostHistory @Username=%s", ("nobody",)) == []


def test_vm_by_hostname(conn):
    vmid = add_vm(conn, "byname-1")
    found = exec_sql(conn, "EXEC dbo.GetVmByHostname @Hostname=%s", ("BYNAME-1",))
    assert found[0]["VMID"] == vmid and found[0]["DrainRequested"] is False
    assert exec_sql(conn, "EXEC dbo.GetVmByHostname @Hostname=%s", ("missing",)) == []


# ------------------------------------------------------------------------ profile reset


def test_profile_reset_request_cancel_and_complete(conn):
    assert exec_sql(conn, "EXEC dbo.RequestProfileReset @Username=%s", ("ghost",))[0]["Result"] == "NotFound"
    assert exec_sql(conn, "EXEC dbo.CancelProfileReset @Username=%s", ("ghost",))[0]["Result"] == "NotFound"

    add_user(conn, "hank", 8001)
    add_vm(conn, "reset-held", status="CheckedOut", username="hank", lease="77777777-7777-7777-7777-777777777777")
    requested = exec_sql(conn, "EXEC dbo.RequestProfileReset @Username=%s, @RequestedBy=%s", ("hank", "admin@contoso.com"))[0]
    assert requested["Result"] == "Requested" and requested["CurrentlyAssigned"] is True
    assert requested["ProfileResetRequestedBy"] == "admin@contoso.com"
    assert requested["ProfileResetRequestedAtUtc"].endswith("Z")
    assert exec_sql(conn, "EXEC dbo.SearchUsers @Query=%s", ("hank",))[0]["ProfileResetPending"] is True

    assert exec_sql(conn, "EXEC dbo.CancelProfileReset @Username=%s", ("hank",))[0]["Result"] == "Cancelled"
    assert exec_sql(conn, "EXEC dbo.CancelProfileReset @Username=%s", ("hank",))[0]["Result"] == "NotPending"

    exec_sql(conn, "EXEC dbo.RequestProfileReset @Username=%s", ("hank",))
    assert exec_sql(conn, "EXEC dbo.CompleteProfileReset @Username=%s", ("hank",))[0]["Result"] == "Completed"
    assert exec_sql(conn, "EXEC dbo.CompleteProfileReset @Username=%s", ("hank",))[0]["Result"] == "NotPending"
    assert one(conn, "SELECT ProfileResetRequestedAt FROM dbo.VmUsers WHERE username='hank'")["ProfileResetRequestedAt"] is None


def begin_reset(conn, username, vmid):
    return exec_sql(conn, "EXEC dbo.BeginProfileReset @Username=%s, @VMID=%s", (username, vmid))[0]["Result"]


def test_profile_reset_is_applied_only_when_nothing_else_uses_the_profile(conn):
    add_user(conn, "ivy", 8101)
    vmid = add_vm(conn, "begin-1")
    other = add_vm(conn, "begin-2")

    assert checkout(conn, "ivy")["VMID"] == vmid
    assert begin_reset(conn, "ivy", vmid) == "NotPending"

    exec_sql(conn, "EXEC dbo.RequestProfileReset @Username=%s", ("ivy",))
    assert begin_reset(conn, "ivy", other) == "NotAssigned"
    assert begin_reset(conn, "ivy", vmid) == "Ready"

    # Another host still waiting to remove the user.
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupPending=1, CleanupUsername='ivy' WHERE VMID=%s", (other,))
    assert begin_reset(conn, "ivy", vmid) == "InUseElsewhere"
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupPending=0, CleanupUsername=NULL WHERE VMID=%s", (other,))

    # A recent heartbeat reporting the user on another host; an old one does not count.
    heartbeat(conn, "begin-2", [session("ivy")])
    assert begin_reset(conn, "ivy", vmid) == "InUseElsewhere"
    exec_sql(conn, "UPDATE dbo.HostHeartbeats SET ReceivedAt=DATEADD(HOUR, -2, SYSUTCDATETIME()) WHERE Hostname='begin-2'")
    assert begin_reset(conn, "ivy", vmid) == "Ready"

    # Its own host reporting the user is expected.
    heartbeat(conn, "begin-1", [session("ivy")])
    assert begin_reset(conn, "ivy", vmid) == "Ready"


def test_sessions_and_users_procedures_exist(conn):
    expected = {
        "GetSessions", "SearchUsers", "GetUserDetails", "GetUserHostHistory", "GetVmByHostname",
        "RequestProfileReset", "CancelProfileReset", "BeginProfileReset", "CompleteProfileReset",
    }
    present = {r["name"] for r in rows(conn, "SELECT name FROM sys.procedures")}
    assert expected <= present
    columns = {r["name"] for r in rows(conn, "SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.VirtualMachines')")}
    assert {"AssignedDate", "LastCheckoutDate"} <= columns
