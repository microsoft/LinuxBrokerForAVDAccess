"""The API's connection pool against the real driver and stored procedures.

System-versioned tables (VirtualMachines, VmScalingRules, ScalingSchedules and
LinuxHostSettings) stamp each change with its transaction's start time, and SQL Server
refuses a change stamped earlier than the row's current version (error 13535). A pooled
connection must therefore begin its transaction when a request takes it, not when the
previous request gave it back.
"""


def _checkout(client, username="alice", avdhost="avd-01"):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost})


def test_the_integration_tests_run_with_the_pool_on(app_module):
    assert app_module._db_pool is not None


def test_a_pooled_connection_can_change_a_row_changed_while_it_sat_idle(client, db, remote, app_module):
    db.run("UPDATE dbo.ScalingPolicy SET StartOnDemandEnabled = 0")
    db.add_vm("lnxhost-01", power="Off", network="Unreachable")
    assert _checkout(client).status_code == 409
    assert app_module._db_pool.idle_count >= 1

    # Another worker changes the host while the connection waits in the pool.
    db.run("UPDATE dbo.VirtualMachines SET PowerState = 'On', NetworkStatus = 'Reachable' "
           "WHERE Hostname = 'lnxhost-01'")

    response = _checkout(client)

    assert response.status_code == 200, response.get_json()
    assert db.vm("lnxhost-01")["VmStatus"] == "CheckedOut"


def test_a_pooled_connection_waits_with_no_transaction_open(client, db, app_module):
    db.add_vm("lnxhost-01")
    assert client.get("/api/vms").status_code == 200

    pooled = app_module._db_pool.acquire(app_module.get_db_connection)
    try:
        # Taken back out, it has begun exactly one transaction: the one this request would use.
        cursor = pooled.connection.cursor()
        cursor.execute("SELECT @@TRANCOUNT")
        assert cursor.fetchone()[0] == 1
    finally:
        app_module._db_pool.release(pooled)

    idle = app_module._db_pool._idle[-1].connection
    cursor = idle.cursor()
    cursor.execute("SELECT @@TRANCOUNT")
    assert cursor.fetchone()[0] == 0
