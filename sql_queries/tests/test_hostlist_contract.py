"""Contract tests for 2.7 the host list (141-143): server-side paging, search, status filters
and sorting, the status chip counts, and importing hosts found in Azure."""

import json

from conftest import add_vm, exec_sql, one, rows


LEASE = "7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C"


def page(conn, **arguments):
    values = {"Search": None, "Status": None, "Sort": "hostname", "Descending": False, "Offset": 0, "PageSize": 50}
    values.update(arguments)
    return rows(conn, "EXEC dbo.GetVmsPaged @Search=%s, @Status=%s, @Sort=%s, @Descending=%s, @Offset=%s, @PageSize=%s",
                tuple(values.values()))


def names(result):
    return [row["Hostname"] for row in result]


def fleet(conn):
    ids = {
        "ready-a": add_vm(conn, "ready-a"),
        "ready-b": add_vm(conn, "ready-b"),
        "busy": add_vm(conn, "busy", status="CheckedOut", username="alice", avdhost="avd", lease=LEASE),
        "gone": add_vm(conn, "gone", status="Released", username="bob", avdhost="avd", lease=LEASE),
        "maint": add_vm(conn, "maint", status="Maintenance"),
        "lost": add_vm(conn, "lost", net="Unreachable"),
        "off": add_vm(conn, "off", power="Off", net="Unreachable"),
        "dirty": add_vm(conn, "dirty", cleanup=True),
    }
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE Hostname='busy'")
    exec_sql(conn, "INSERT INTO dbo.HostHeartbeats (Hostname, ReceivedAt, OsName, AgentVersion, SessionCount, SessionsJson) VALUES "
                   "('busy', DATEADD(SECOND, -30, SYSUTCDATETIME()), N'Ubuntu 24.04', '1.1.0', 1, %s), "
                   "('ready-a', DATEADD(SECOND, -300, SYSUTCDATETIME()), N'Red Hat Enterprise Linux 9.4', '1.0.0', 0, '[]')",
             (json.dumps([{"username": "alice", "state": "active"}]),))
    return ids


def test_pages_carry_the_total_and_the_heartbeat(conn):
    fleet(conn)
    first = page(conn, PageSize=3)
    assert names(first) == ["busy", "dirty", "gone"]
    assert all(row["TotalCount"] == 8 for row in first)
    busy = first[0]
    assert (busy["OsName"], busy["AgentVersion"], busy["SessionCount"], busy["DrainRequested"]) == ("Ubuntu 24.04", "1.1.0", 1, True)
    assert 25 <= busy["HeartbeatAgeSeconds"] <= 90 and busy["LastHeartbeatUtc"].endswith("Z")
    assert busy["CurrentSettingsVersion"] is not None and "LeaseId" not in busy

    third = page(conn, Offset=6, PageSize=3)
    assert names(third) == ["ready-a", "ready-b"]
    assert page(conn, Offset=30) == []


def test_every_status_filter(conn):
    fleet(conn)
    expected = {
        "ready": ["ready-a", "ready-b"],
        "in-use": ["busy"],
        "released": ["gone"],
        "maintenance": ["maint"],
        "draining": ["busy"],
        "unreachable": ["lost"],
        "off": ["off"],
        "cleanup": ["dirty"],
        "all": ["busy", "dirty", "gone", "lost", "maint", "off", "ready-a", "ready-b"],
        "READY": ["ready-a", "ready-b"],
    }
    for status, hostnames in expected.items():
        assert names(page(conn, Status=status)) == hostnames, status
    assert page(conn, Status="ready")[0]["Ready"] is True


def test_search_matches_host_address_user_and_os_literally(conn):
    fleet(conn)
    add_vm(conn, "lnx_01")
    add_vm(conn, "lnxa01")
    assert names(page(conn, Search="alice")) == ["busy"]
    assert names(page(conn, Search="red hat")) == ["ready-a"]
    assert names(page(conn, Search="lnx_0")) == ["lnx_01"]
    assert names(page(conn, Search="%")) == []
    assert len(page(conn, Search="10.0.0.1")) == 10
    assert names(page(conn, Search="  ")) == names(page(conn))


def test_sorting_is_whitelisted(conn):
    ids = fleet(conn)
    assert names(page(conn, Descending=True))[:2] == ["ready-b", "ready-a"]
    by_id = page(conn, Sort="vmid", Descending=True)
    assert [row["VMID"] for row in by_id] == sorted(ids.values(), reverse=True)
    heartbeat = names(page(conn, Sort="heartbeat", Descending=True))
    assert heartbeat[:2] == ["ready-a", "busy"]
    assert names(page(conn, Sort="status"))[0] in ("dirty", "lost", "ready-a", "ready-b")
    assert names(page(conn, Sort="'; DROP TABLE dbo.VirtualMachines; --")) == names(page(conn))
    assert one(conn, "SELECT COUNT(*) AS N FROM dbo.VirtualMachines")["N"] == 8


def test_page_size_is_clamped(conn):
    for index in range(205):
        exec_sql(conn, "INSERT INTO dbo.VirtualMachines (Hostname, PowerState, NetworkStatus, VmStatus) VALUES (%s, 'Off', 'Unreachable', 'Available')",
                 (f"bulk-{index:03}",))
    assert len(page(conn, PageSize=1000)) == 200
    assert len(page(conn, PageSize=0)) == 50


def test_status_counts_follow_the_search(conn):
    fleet(conn)
    counts = one(conn, "EXEC dbo.GetVmStatusCounts")
    assert counts == {"All": 8, "Ready": 2, "InUse": 1, "Released": 1, "Maintenance": 1, "Draining": 1,
                      "Unreachable": 1, "Off": 1, "Cleanup": 1}
    narrowed = one(conn, "EXEC dbo.GetVmStatusCounts @Search=%s", ("ready",))
    assert (narrowed["All"], narrowed["Ready"], narrowed["InUse"]) == (2, 2, 0)


def test_an_imported_host_waits_for_the_probe(conn):
    imported = one(conn, "EXEC dbo.ImportLinuxHostVm @Hostname=%s, @IPAddress=%s, @PowerState=%s", ("lnx-new", "10.1.0.9", "On"))
    assert imported["Result"] == "Imported"
    vm = one(conn, "SELECT * FROM dbo.VirtualMachines WHERE VMID=%s", (imported["VMID"],))
    assert (vm["PowerState"], vm["NetworkStatus"], vm["VmStatus"], vm["IPAddress"]) == ("On", "Unreachable", "Available", "10.1.0.9")
    assert vm["Description"] == "Imported from Azure."

    again = one(conn, "EXEC dbo.ImportLinuxHostVm @Hostname=%s, @IPAddress=%s", ("lnx-new", "10.1.0.10"))
    assert (again["Result"], again["VMID"]) == ("Exists", imported["VMID"])
    assert one(conn, "SELECT IPAddress FROM dbo.VirtualMachines WHERE VMID=%s", (imported["VMID"],))["IPAddress"] == "10.1.0.9"

    off = one(conn, "EXEC dbo.ImportLinuxHostVm @Hostname=%s, @IPAddress=%s, @PowerState=%s", ("lnx-off", "10.1.0.11", "Deallocated"))
    assert one(conn, "SELECT PowerState FROM dbo.VirtualMachines WHERE VMID=%s", (off["VMID"],))["PowerState"] == "Off"
