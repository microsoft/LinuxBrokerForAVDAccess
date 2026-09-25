"""2.5 scaling policy against the real stored procedures and driver."""

import pytest


RULE = {"minvms": 2, "maxvms": 6, "scaleupratio": 70, "scaleupincrement": 1, "scaledownratio": 30, "scaledownincrement": 1}
EVERY_DAY = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class Compute:
    def __init__(self):
        self.operations = []
        compute = self

        class VirtualMachines:
            def begin_start(self, resource_group, name):
                compute.operations.append(("start", name))

            def begin_power_off(self, resource_group, name):
                compute.operations.append(("power_off", name))

            def begin_deallocate(self, resource_group, name):
                compute.operations.append(("deallocate", name))

            def instance_view(self, resource_group, name):
                error = Exception("not found")
                error.status_code = 404
                raise error

        self.virtual_machines = VirtualMachines()


@pytest.fixture
def compute(app_module, monkeypatch):
    fake = Compute()
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)
    return fake


def _window(client, name, start, end, **values):
    payload = {"name": name, "days": EVERY_DAY, "start": start, "end": end, **RULE, **values}
    return client.post("/api/scaling/schedules/create", json=payload)


def test_windows_drive_a_real_scaling_run(client, db, compute):
    db.add_vm("lnxhost-01")
    for index in range(2, 6):
        db.add_vm(f"lnxhost-0{index}", power="Off", network="Unreachable")

    # Two windows that between them cover the whole week, so "now" is always in one.
    assert _window(client, "Mornings", "00:00", "12:00", minvms=3).status_code == 201
    assert _window(client, "Afternoons", "12:00", "00:00", minvms=3).status_code == 201
    clash = _window(client, "Lunch", "11:00", "13:00")
    assert clash.status_code == 409 and "Mornings" in clash.get_json()["error"]

    policy = client.get("/api/scaling/policy").get_json()
    assert policy["ActivePhase"]["Source"] == "Schedule" and policy["ActivePhase"]["MinVMs"] == 3
    assert policy["NextChange"]["PhaseName"] in ("Mornings", "Afternoons")

    preview = client.get("/api/scaling/preview").get_json()
    assert preview["Action"] == "PowerOn" and len(preview["Candidates"]) == 2
    assert db.one("SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")["c"] == 0

    ran = client.post("/api/scaling/trigger")
    assert ran.status_code == 200, ran.get_json()
    assert sorted(ran.get_json()["PoweredOnVMs"]) == sorted(preview["Candidates"])
    log = db.one("SELECT TOP 1 PhaseName, MinVMs, ServiceableVMs FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert log["PhaseName"] in ("Mornings", "Afternoons") and log["MinVMs"] == 3 and log["ServiceableVMs"] == 1


def test_proposed_values_and_the_time_zone(client, db):
    db.add_vm("lnxhost-01")
    zones = {zone["Name"] for zone in client.get("/api/scaling/timezones").get_json()}
    assert "Tokyo Standard Time" in zones

    updated = client.post("/api/scaling/policy/update", json={"timezone": "Tokyo Standard Time"})
    assert updated.status_code == 200 and client.get("/api/scaling/policy").get_json()["TimeZone"] == "Tokyo Standard Time"
    assert client.post("/api/scaling/policy/update", json={"timezone": "Nowhere"}).status_code == 400

    proposed = client.post("/api/scaling/preview", json={"rule": dict(RULE, minvms=4, name="Draft")}).get_json()
    assert proposed["Phase"]["Name"] == "Draft" and proposed["Phase"]["MinVMs"] == 4
    assert proposed["TimeZone"] == "Tokyo Standard Time"


def test_editing_and_deleting_a_window(client, db):
    created = _window(client, "Business hours", "08:00", "18:00").get_json()
    schedule_id = created["ScheduleID"]

    updated = client.post(f"/api/scaling/schedules/{schedule_id}/update",
                          json={"name": "Business hours", "days": ["mon"], "start": "07:00", "end": "19:00", "enabled": False, **RULE})
    assert updated.status_code == 200
    saved = client.get("/api/scaling/policy").get_json()["Schedules"][0]
    assert saved["Days"] == ["mon"] and saved["StartTime"] == "07:00" and saved["Enabled"] is False

    assert client.post(f"/api/scaling/schedules/{schedule_id}/delete").status_code == 200
    assert client.get("/api/scaling/policy").get_json()["Schedules"] == []
