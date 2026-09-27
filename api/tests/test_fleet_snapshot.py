"""4.7 fleet snapshot: every scaling run logs the fleet's figures for the monitoring workbook and
alerts, and a snapshot that cannot be read never fails the run."""

import logging
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MISSING = "(2812, b\"Could not find stored procedure '{}'.\")"
SNAPSHOT = {
    "ReadyHosts": 2, "PoweredOn": 5, "Serviceable": 4, "InUse": 2, "Waiting": 1, "Booting": 1,
    "StaleHeartbeats": 0, "NfsUnreachable": 0, "XrdpInactive": 1, "Draining": 1, "Maintenance": 0,
    "TotalHosts": 8, "EffectiveMinVMs": None, "MaxVMs": None, "StartOnDemandEnabled": True,
    "StaleAfterSeconds": 180,
}


def snapshots(caplog):
    return [record for record in caplog.records if record.getMessage() == "fleet snapshot"]


def trigger(client):
    return client.post("/api/scaling/trigger", json={})


def test_each_scaling_run_logs_the_fleet_after_scaling(client, fake_db, caplog):
    fake_db.fetchall_rows["GetVms"] = []
    fake_db.fetchone_rows["GetFleetSnapshot"] = dict(SNAPSHOT)
    caplog.set_level(logging.INFO, logger="linuxbroker.api")

    assert trigger(client).status_code == 200

    procs = [call["proc"] for call in fake_db.calls]
    assert procs.index("TriggerScalingLogic") < procs.index("GetFleetSnapshot")
    [record] = snapshots(caplog)
    assert record.levelno == logging.INFO
    assert (record.ReadyHosts, record.Waiting, record.XrdpInactive, record.TotalHosts) == (2, 1, 1, 8)
    assert record.StartOnDemandEnabled == 1 and type(record.StartOnDemandEnabled) is int
    # With no scaling rule the database has no minimum or maximum, and a dimension is never empty.
    assert not hasattr(record, "EffectiveMinVMs") and not hasattr(record, "MaxVMs")


def test_the_logged_figures_are_the_procedures_columns(app_module):
    sql = (REPO_ROOT / "sql_queries" / "157_create_procedure-GetFleetSnapshot.sql").read_text()
    final_select = sql[sql.rindex("SELECT"):sql.rindex("FROM dbo.VirtualMachines")]

    assert tuple(re.findall(r"\bAS (\w+)", final_select)) == app_module.FLEET_SNAPSHOT_FIELDS


def test_a_database_without_the_snapshot_is_logged_once(client, fake_db, caplog):
    fake_db.fetchall_rows["GetVms"] = []
    fake_db.raise_on_execute["GetFleetSnapshot"] = MISSING.format("GetFleetSnapshot")

    assert trigger(client).status_code == 200
    assert trigger(client).status_code == 200
    assert caplog.text.count("GetFleetSnapshot is not deployed yet") == 1
    assert snapshots(caplog) == []


def test_a_snapshot_that_cannot_be_read_never_fails_the_scaling_run(client, fake_db, caplog):
    fake_db.fetchall_rows["GetVms"] = []
    fake_db.fetchall_rows["TriggerScalingLogic"] = [
        {"ActionType": "PowerOn", "VMName": "lnx-01", "VMID": 1, "StopMode": None, "ActivityID": 3},
    ]
    fake_db.raise_on_execute["GetFleetSnapshot"] = "connection reset"

    first = trigger(client)
    trigger(client)

    assert first.status_code == 200 and first.get_json()["PoweredOnVMs"] == ["lnx-01"]
    assert caplog.text.count("Could not read the fleet snapshot.") == 2


def test_an_unreachable_database_skips_the_snapshot(app_module, monkeypatch, caplog):
    monkeypatch.setattr(app_module, "get_db_connection", lambda: None)

    assert app_module.log_fleet_snapshot() is None
    assert "Could not read the fleet snapshot." in caplog.text


def test_no_row_logs_nothing(app_module, fake_db, caplog):
    caplog.set_level(logging.INFO, logger="linuxbroker.api")

    assert app_module.log_fleet_snapshot() is None
    assert snapshots(caplog) == []
