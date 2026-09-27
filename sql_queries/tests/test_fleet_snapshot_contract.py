"""Contract tests for 4.7 fleet monitoring (157): dbo.GetFleetSnapshot, the one row the API logs
to Application Insights after every scaling run for the monitoring workbook and alerts."""

from conftest import add_vm, exec_sql


def snapshot(conn, stale_after=None):
    return exec_sql(conn, "EXEC dbo.GetFleetSnapshot @StaleAfterSeconds=%s", (stale_after,))[0]


def heartbeat(conn, hostname, seconds_ago=0, nfs=True, xrdp=True):
    exec_sql(conn, "INSERT INTO dbo.HostHeartbeats (Hostname, ReceivedAt, NfsReachable, XrdpActive) "
                   "VALUES (%s, DATEADD(SECOND, -%s, SYSUTCDATETIME()), %s, %s)", (hostname, seconds_ago, nfs, xrdp))


def started(conn, vmid, seconds_ago):
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET PowerStateChangedDate=DATEADD(SECOND, -%s, GETDATE()) WHERE VMID=%s",
             (seconds_ago, vmid))


def set_rule(conn, min_vms, max_vms):
    exec_sql(conn, "UPDATE dbo.VmScalingRules SET MinVMs=%s, MaxVMs=%s", (min_vms, max_vms))


def test_an_empty_fleet_reports_zeros_and_the_active_rule(conn):
    assert snapshot(conn) == {
        "ReadyHosts": 0, "PoweredOn": 0, "Serviceable": 0, "InUse": 0, "Waiting": 0, "Booting": 0,
        "StaleHeartbeats": 0, "NfsUnreachable": 0, "XrdpInactive": 0, "Draining": 0, "Maintenance": 0,
        "TotalHosts": 0, "EffectiveMinVMs": 2, "MaxVMs": 10, "StartOnDemandEnabled": True,
        # Three reconcile intervals of 60 seconds.
        "StaleAfterSeconds": 180,
    }


def test_the_snapshot_counts_each_host_once_by_state(conn):
    heartbeat(conn, "ready")
    add_vm(conn, "ready")
    heartbeat(conn, "busy")
    add_vm(conn, "busy", status="CheckedOut", username="bob", avdhost="avd", lease="7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C")
    heartbeat(conn, "cleaning")
    add_vm(conn, "cleaning", cleanup=True)
    started(conn, add_vm(conn, "booting", net="Unreachable"), 60)
    add_vm(conn, "off", power="Off", net="Unreachable")
    heartbeat(conn, "draining")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE VMID=%s", (add_vm(conn, "draining"),))
    # Maintenance hosts may be rebooting, so an old heartbeat is not stale.
    heartbeat(conn, "patching", seconds_ago=3600)
    add_vm(conn, "patching", status="Maintenance")
    exec_sql(conn, "EXEC dbo.RecordCheckoutEvent @Username='dave', @AvdHost='avd-01', @Outcome='Starting', "
                   "@DurationMs=100, @Hostname=NULL")

    row = snapshot(conn)
    assert {key: row[key] for key in ("ReadyHosts", "PoweredOn", "Serviceable", "InUse", "Waiting", "Booting",
                                      "StaleHeartbeats", "Draining", "Maintenance", "TotalHosts")} == {
        "ReadyHosts": 1,
        "PoweredOn": 6,
        # ready, busy, cleaning and booting; the draining and maintenance hosts cannot take a user.
        "Serviceable": 4,
        "InUse": 2,
        "Waiting": 1,
        "Booting": 1,
        "StaleHeartbeats": 0,
        "Draining": 1,
        "Maintenance": 1,
        "TotalHosts": 7,
    }


def test_a_heartbeat_is_stale_only_after_the_host_has_had_time_to_report(conn):
    heartbeat(conn, "old", seconds_ago=600)
    add_vm(conn, "old", changed_minutes=30)
    add_vm(conn, "silent", changed_minutes=30)
    # Reachable a minute after starting, before its first heartbeat.
    started(conn, add_vm(conn, "new"), 60)
    heartbeat(conn, "fresh", seconds_ago=30)
    add_vm(conn, "fresh", changed_minutes=30)
    # A host the probe cannot reach is reported as unreachable elsewhere, not as a stale heartbeat.
    heartbeat(conn, "lost", seconds_ago=600)
    add_vm(conn, "lost", net="Unreachable", changed_minutes=30)

    assert snapshot(conn)["StaleHeartbeats"] == 2
    # A longer allowance keeps the ten-minute-old heartbeat fresh.
    row = snapshot(conn, stale_after=900)
    assert (row["StaleHeartbeats"], row["StaleAfterSeconds"]) == (1, 900)


def test_the_default_allowance_follows_the_reconcile_interval(conn):
    exec_sql(conn, "UPDATE dbo.LinuxHostSettings SET ReconcileIntervalSeconds=120 WHERE SettingsScope='Global'")
    assert snapshot(conn)["StaleAfterSeconds"] == 360
    assert snapshot(conn, stale_after=0)["StaleAfterSeconds"] == 360


def test_fresh_heartbeats_report_the_home_share_and_xrdp(conn):
    heartbeat(conn, "no-nfs", nfs=False)
    add_vm(conn, "no-nfs")
    heartbeat(conn, "no-xrdp", xrdp=False)
    add_vm(conn, "no-xrdp", status="CheckedOut", username="erin", avdhost="avd", lease="1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9")
    # Stale reports and powered-off hosts do not count.
    heartbeat(conn, "stale-report", seconds_ago=600, nfs=False, xrdp=False)
    add_vm(conn, "stale-report", changed_minutes=30)
    heartbeat(conn, "stopped", nfs=False, xrdp=False)
    add_vm(conn, "stopped", power="Off", net="Unreachable")
    # Nor does a host in maintenance, which an administrator is working on.
    heartbeat(conn, "patching", nfs=False, xrdp=False)
    add_vm(conn, "patching", status="Maintenance")

    row = snapshot(conn)
    assert (row["NfsUnreachable"], row["XrdpInactive"], row["Maintenance"]) == (1, 1, 1)


def test_the_minimum_is_read_as_scaling_reads_it(conn):
    set_rule(conn, 0, 4)
    row = snapshot(conn)
    assert (row["EffectiveMinVMs"], row["MaxVMs"], row["StartOnDemandEnabled"]) == (0, 4, True)

    exec_sql(conn, "EXEC dbo.SetScalingPolicyStartOnDemand @Enabled=0, @MaxPendingStarts=NULL, @UpdatedBy=NULL")
    row = snapshot(conn)
    assert (row["EffectiveMinVMs"], row["MaxVMs"], row["StartOnDemandEnabled"]) == (1, 4, False)

    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    row = snapshot(conn)
    assert (row["EffectiveMinVMs"], row["MaxVMs"]) == (None, None)
