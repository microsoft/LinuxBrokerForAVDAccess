"""4.1 start on demand and scale to zero: a checkout that finds no ready host starts one and
answers 202, a waiting user's next request probes the hosts starting for it, the AVD host
script's version is recorded, and the policy, preview and metrics carry the new settings."""

import json
import re
import types
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"
MISSING = "(2812, b\"Could not find stored procedure '{}'.\")"
NO_HOST = [{"Message": "No available VM found"}]


def checkout_row(**values):
    row = {"VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5", "LeaseId": LEASE_ID, "CheckoutType": "Assigned",
           "ProfileResetRequested": False}
    row.update(values)
    return row


def reservation(result, **values):
    row = {"Result": result, "VMID": None, "VMName": None, "PreviousNetworkStatus": None, "ActivityID": None,
           "RetryAfterSeconds": None, "BootingHostsJson": "[]", "Waiting": 1, "Booting": 0}
    row.update(values)
    return row


def started(**values):
    row = {"VMID": 7, "VMName": "lnx-07", "PreviousNetworkStatus": "Unreachable", "ActivityID": 41,
           "RetryAfterSeconds": 75, "Booting": 1}
    row.update(values)
    return reservation("Started", **row)


def procs(fake_db):
    return [call["proc"] for call in fake_db.calls]


def events(fake_db):
    return [call["params"] for call in fake_db.calls if call["proc"] == "RecordCheckoutEvent"]


def checkout(client, **extra):
    return client.post("/api/vms/checkout", json={"username": "a.lice", "avdhost": "avd-01", **extra})


@pytest.fixture
def provisioned(app_module, monkeypatch):
    calls = []
    monkeypatch.setattr(app_module, "create_or_update_remote_user", lambda *args: calls.append(args) or True)
    monkeypatch.setattr(app_module, "release_vm_assignment", lambda vmid, lease_id: None)
    return calls


@pytest.fixture
def azure(app_module, fake_db, monkeypatch):
    state = {"starts": [], "refuse": False, "commits": None}

    def begin_start(resource_group, name):
        state["commits"] = fake_db.commits
        if state["refuse"]:
            raise RuntimeError("Operation 'start' is not allowed on VM 'lnx-07' in region xyz.")
        state["starts"].append((resource_group, name))

    client = types.SimpleNamespace(virtual_machines=types.SimpleNamespace(begin_start=begin_start))
    monkeypatch.setattr(app_module, "get_compute_client", lambda: client)
    return state


@pytest.fixture
def probes(app_module, monkeypatch):
    state = {"up": set(), "asked": []}

    def probe(ip_address):
        state["asked"].append(ip_address)
        return ip_address in state["up"]

    monkeypatch.setattr(app_module, "probe_ssh", probe)
    return state


def booting(*hosts):
    return json.dumps([{"VMID": vmid, "Hostname": name, "IPAddress": ip} for vmid, name, ip in hosts])


# ------------------------------------------------------------------ starting a host


def test_no_ready_host_starts_one_and_asks_the_avd_host_to_wait(client, fake_db, provisioned, azure, audit_entries):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = started()

    response = checkout(client, clientVersion="2.0.0")

    assert response.status_code == 202
    assert response.headers["Retry-After"] == "75"
    assert response.get_json() == {
        "status": "Starting", "reason": "Started", "retryAfterSeconds": 75,
        "message": "A Linux host is starting for you. Ask again in 75 seconds.",
    }
    assert azure["starts"] == [("resource-group", "lnx-07")]
    assert fake_db.latest_call("ReserveVmForStart")["params"] == ("alice", "avd-01")
    assert provisioned == []

    [entry] = [entry for entry in audit_entries if entry["action"] == "vm.start_on_demand"]
    assert (entry["targetType"], entry["targetId"], entry["outcome"]) == ("vm", "lnx-07", "success")
    assert json.loads(entry["detailJson"]) == {"username": "alice", "avdhost": "avd-01", "clientVersion": "2.0.0",
                                               "activityId": 41, "waiting": 1, "starting": 1}

    [params] = events(fake_db)
    assert params[:3] == ("alice", "avd-01", "Starting") and params[4:] == ("lnx-07", "2.0.0")
    # The reservation holds the scaling lock, so it is committed before Azure is asked:
    # the checkout's commit, then the reservation's.
    assert azure["commits"] == 2


def test_azure_refusing_the_start_puts_the_host_back_and_refuses_the_checkout(client, fake_db, provisioned, azure, audit_entries):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = started()
    azure["refuse"] = True

    response = checkout(client)

    assert response.status_code == 409
    assert response.get_json()["error"] == "No available VM found. Please try again."
    assert "region xyz" not in response.get_data(as_text=True)
    assert fake_db.latest_call("UpdateVmAttributes")["params"] == (7, "Off", "Unreachable", None)
    assert fake_db.latest_call("AppendScalingActivityNote")["params"] == (41, "Starting lnx-07 failed, so it was recorded as off again.")
    [entry] = [entry for entry in audit_entries if entry["action"] == "vm.start_on_demand"]
    assert entry["outcome"] == "failure"
    assert json.loads(entry["detailJson"])["error"] == "The Azure start operation could not be requested."
    assert events(fake_db)[0][2] == "NoneAvailable"


def test_a_missing_subscription_is_treated_as_a_refused_start(client, fake_db, provisioned, azure, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", "")
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = started()

    assert checkout(client).status_code == 409
    assert azure["starts"] == []
    assert fake_db.latest_call("UpdateVmAttributes")["params"][:2] == (7, "Off")


@pytest.mark.parametrize("seconds,expected", [(None, 30), (1, 5), (500, 300), ("abc", 30), (45, 45)])
def test_the_wait_is_kept_between_five_seconds_and_five_minutes(client, fake_db, provisioned, azure, seconds, expected):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = started(RetryAfterSeconds=seconds)
    response = checkout(client)
    assert response.headers["Retry-After"] == str(expected) and response.get_json()["retryAfterSeconds"] == expected


# ------------------------------------------------------------------ hosts already starting


def test_a_waiting_user_is_given_a_starting_host_as_soon_as_it_answers(client, fake_db, provisioned, azure, probes):
    fake_db.fetchall_sequence["CheckoutVm"] = [NO_HOST, [checkout_row(VMID=7, Hostname="lnx-07", IPAddress="10.0.0.7")]]
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation(
        "AlreadyStarting", RetryAfterSeconds=40, Booting=2,
        BootingHostsJson=booting((7, "lnx-07", "10.0.0.7"), (8, "lnx-08", "10.0.0.8")))
    probes["up"] = {"10.0.0.7"}

    response = checkout(client)

    assert response.status_code == 200
    assert response.get_json()["Hostname"] == "lnx-07"
    assert sorted(probes["asked"]) == ["10.0.0.7", "10.0.0.8"]
    marked = [call["params"] for call in fake_db.calls if call["proc"] == "SetVmNetworkStatus"]
    assert marked == [(7, "Reachable")]
    assert procs(fake_db).count("CheckoutVm") == 2
    assert azure["starts"] == []
    assert events(fake_db)[0][2:5:2] == ("Assigned", "lnx-07")


def test_a_waiting_user_waits_again_while_no_starting_host_answers(client, fake_db, provisioned, probes):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation(
        "AlreadyStarting", RetryAfterSeconds=40, BootingHostsJson=booting((7, "lnx-07", "10.0.0.7")))

    response = checkout(client)

    assert response.status_code == 202 and response.headers["Retry-After"] == "40"
    assert response.get_json()["message"] == "A Linux host is starting. Ask again in 40 seconds."
    assert probes["asked"] == ["10.0.0.7"]
    assert "SetVmNetworkStatus" not in procs(fake_db)
    assert procs(fake_db).count("CheckoutVm") == 1
    [params] = events(fake_db)
    assert params[2] == "Starting" and params[4] is None


def test_a_host_that_answered_but_went_to_someone_else_means_waiting_again(client, fake_db, provisioned, probes):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation(
        "AlreadyStarting", RetryAfterSeconds=30, BootingHostsJson=booting((7, "lnx-07", "10.0.0.7")))
    probes["up"] = {"10.0.0.7"}

    assert checkout(client).status_code == 202
    assert procs(fake_db).count("CheckoutVm") == 2


def test_probing_skips_unusable_entries_and_survives_a_database_failure(app_module, fake_db, probes):
    hosts = [{"VMID": 7, "Hostname": "lnx-07", "IPAddress": "10.0.0.7"}, {"VMID": None, "IPAddress": "10.0.0.9"},
             {"VMID": 8, "Hostname": "lnx-08"}, "junk"]
    probes["up"] = {"10.0.0.7"}
    assert app_module.mark_started_hosts_reachable(hosts) == 1
    assert probes["asked"] == ["10.0.0.7"]
    assert app_module.mark_started_hosts_reachable(None) == 0

    fake_db.raise_on_execute["SetVmNetworkStatus"] = "connection reset"
    assert app_module.mark_started_hosts_reachable(hosts) == 0


def test_the_probe_connects_to_the_ssh_port_with_a_timeout(app_module, monkeypatch):
    attempts = []

    class Connection:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def connect(address, timeout):
        attempts.append((address, timeout))
        if address[0] == "10.0.0.9":
            raise OSError("timed out")
        return Connection()

    monkeypatch.setattr(app_module.socket, "create_connection", connect)
    assert app_module.probe_ssh("10.0.0.7") is True
    assert app_module.probe_ssh("10.0.0.9") is False
    assert attempts == [(("10.0.0.7", 22), 2), (("10.0.0.9", 22), 2)]


# ------------------------------------------------------------------ the other decisions


def test_a_host_that_became_ready_is_checked_out_at_once(client, fake_db, provisioned):
    fake_db.fetchall_sequence["CheckoutVm"] = [NO_HOST, [checkout_row()]]
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation("ReadyNow")

    response = checkout(client)

    assert response.status_code == 200 and response.get_json()["Hostname"] == "lnx-05"
    assert len(provisioned) == 1


def test_a_ready_host_taken_by_someone_else_means_waiting(client, fake_db, provisioned):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation("ReadyNow")

    response = checkout(client)

    assert response.status_code == 202 and response.headers["Retry-After"] == "30"
    assert response.get_json()["reason"] == "ReadyNow"
    assert response.get_json()["message"] == "No Linux host is ready yet. Ask again in 30 seconds."


def test_busy_scaling_means_asking_again_shortly(client, fake_db, provisioned):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation("Busy", RetryAfterSeconds=30)

    response = checkout(client)
    assert response.status_code == 202 and response.get_json()["reason"] == "Busy"
    assert procs(fake_db).count("CheckoutVm") == 1


@pytest.mark.parametrize("row", [reservation("Disabled"), reservation("AtMaximum"), reservation("NoCandidate"),
                                 reservation("Unexpected"), None])
def test_no_host_to_start_refuses_the_checkout_as_before(client, fake_db, provisioned, azure, row):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    if row is not None:
        fake_db.fetchone_rows["ReserveVmForStart"] = row

    response = checkout(client)

    assert response.status_code == 409
    assert response.get_json()["error"] == "No available VM found. Please try again."
    assert azure["starts"] == [] and events(fake_db)[0][2] == "NoneAvailable"


def test_a_database_without_start_on_demand_is_logged_once(client, fake_db, provisioned, caplog):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    fake_db.raise_on_execute["ReserveVmForStart"] = MISSING.format("ReserveVmForStart")

    assert checkout(client).status_code == 409
    assert checkout(client).status_code == 409
    assert caplog.text.count("ReserveVmForStart is not deployed yet") == 1

    fake_db.raise_on_execute["ReserveVmForStart"] = "connection reset"
    checkout(client)
    checkout(client)
    assert caplog.text.count("Could not decide whether to start a host for alice") == 2


def test_an_unreachable_database_while_deciding_is_not_recorded(client, fake_db, provisioned, app_module, monkeypatch):
    fake_db.fetchall_rows["CheckoutVm"] = NO_HOST
    connections = {"count": 0}
    real_connect = fake_db.connect

    def connect():
        connections["count"] += 1
        return real_connect() if connections["count"] == 1 else None

    monkeypatch.setattr(app_module, "get_db_connection", connect)
    response = checkout(client)
    assert response.get_json()["error"] == "Database connection failed."
    assert connections["count"] == 2


def test_a_failing_second_checkout_is_a_server_error(client, fake_db, provisioned):
    fake_db.fetchall_sequence["CheckoutVm"] = [NO_HOST, [{"ErrorNumber": 1205, "Message": "Deadlock"}]]
    fake_db.fetchone_rows["ReserveVmForStart"] = reservation("ReadyNow")

    assert checkout(client).status_code == 500
    assert events(fake_db)[0][2] == "Error"


# ------------------------------------------------------------------ the script's version


@pytest.mark.parametrize("value,recorded", [
    ("2.0.0", "2.0.0"), (" 2.1.0-beta+7 ", "2.1.0-beta+7"), ("", None), ("x" * 33, None), ("2.0; DROP", None),
    (200, None), (None, None), ("-2", None),
])
def test_only_a_plain_client_version_is_recorded(client, fake_db, provisioned, value, recorded):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]

    assert checkout(client, clientVersion=value).status_code == 200

    [call] = [call for call in fake_db.calls if call["proc"] == "RecordCheckoutEvent"]
    if recorded is None:
        assert len(call["params"]) == 5 and "@ClientVersion" not in call["sql"]
    else:
        assert call["params"][5] == recorded and "@ClientVersion = %s" in call["sql"]


def test_an_admin_checkout_audit_names_the_client_version(auth_client, fake_db, provisioned, audit_entries):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    client = auth_client({"roles": ["FullAccess"], "scp": "access_as_user"})

    response = client.post("/api/vms/checkout", json={"username": "alice", "avdhost": "avd-01", "clientVersion": "2.0.0"},
                           headers=auth_client.headers)

    assert response.status_code == 200
    [entry] = [entry for entry in audit_entries if entry["action"] == "vm.checkout"]
    assert json.loads(entry["detailJson"])["clientVersion"] == "2.0.0"


def test_a_database_that_predates_the_client_version_still_records_the_event(client, fake_db, provisioned, app_module, monkeypatch, caplog):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    rejected = []

    class Cursor:
        def __init__(self, inner):
            self.inner = inner

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def execute(self, sql, params=None):
            if "@ClientVersion" in sql:
                rejected.append(params)
                raise RuntimeError("(8145, b'@ClientVersion is not a parameter for procedure RecordCheckoutEvent.')")
            return self.inner.execute(sql, params)

        def __getattr__(self, name):
            return getattr(self.inner, name)

    real_connect = fake_db.connect

    def connect():
        connection = real_connect()
        real_cursor = connection.cursor
        connection.cursor = lambda as_dict=False: Cursor(real_cursor(as_dict=as_dict))
        return connection

    monkeypatch.setattr(app_module, "get_db_connection", connect)

    assert checkout(client, clientVersion="2.0.0").status_code == 200
    assert checkout(client, clientVersion="2.0.0").status_code == 200

    # The first event is written again without the version; the next leaves it out at once.
    assert len(rejected) == 1
    recorded = events(fake_db)
    assert len(recorded) == 2 and all(len(params) == 5 for params in recorded)
    assert caplog.text.count("does not take @ClientVersion yet") == 1


def test_the_current_script_version_is_the_one_the_avd_host_script_sends(app_module):
    script = (REPO_ROOT / "avd_host" / "broker" / "Connect-LinuxBroker.ps1").read_text(encoding="ascii")

    [version] = re.findall(r"^\$ScriptVersion = '([^']+)'", script, re.MULTILINE)

    assert version == app_module.AVD_HOST_SCRIPT_VERSION
    assert app_module.CLIENT_VERSION_RE.match(version) and len(version) <= app_module.CLIENT_VERSION_MAX_CHARS


# ------------------------------------------------------------------ policy


def policy_row(**values):
    row = {"TimeZone": "UTC", "LocalTime": "2026-09-24T10:15:00", "StartOnDemandEnabled": True, "MaxPendingStarts": 2,
           "ZeroMinimumCount": 1, "AvdHostsSeen": 4, "AvdHostsOutdated": 1,
           "OutdatedAvdHostsJson": json.dumps([{"AvdHost": "avd-03"}]),
           "AvdClientVersionsJson": json.dumps([{"ClientVersion": "1.9.0", "AvdHosts": 1}, {"ClientVersion": "2.0.0", "AvdHosts": 2}])}
    row.update(values)
    return row


def test_the_policy_reports_start_on_demand_and_the_avd_host_scripts(client, fake_db):
    fake_db.fetchone_rows["GetScalingPolicy"] = policy_row()

    policy = client.get("/api/scaling/policy").get_json()

    assert (policy["StartOnDemandEnabled"], policy["MaxPendingStarts"], policy["ZeroMinimumCount"]) == (True, 2, 1)
    assert policy["AvdHostScripts"] == {
        "Seen": 4, "Outdated": 1, "OutdatedHostnames": ["avd-03"], "CurrentVersion": "2.0.0",
        "Versions": [{"ClientVersion": "1.9.0", "AvdHosts": 1, "Current": False},
                     {"ClientVersion": "2.0.0", "AvdHosts": 2, "Current": True}],
    }


def test_the_policy_of_an_older_database_has_no_start_on_demand(client, fake_db):
    fake_db.fetchone_rows["GetScalingPolicy"] = {"TimeZone": "UTC"}
    policy = client.get("/api/scaling/policy").get_json()
    assert policy["StartOnDemandEnabled"] is None and policy["MaxPendingStarts"] is None
    assert policy["AvdHostScripts"] is None


def test_no_avd_host_asked_means_an_empty_summary(client, fake_db):
    fake_db.fetchone_rows["GetScalingPolicy"] = policy_row(AvdHostsSeen=0, AvdHostsOutdated=0, OutdatedAvdHostsJson=None,
                                                           AvdClientVersionsJson=None)
    scripts = client.get("/api/scaling/policy").get_json()["AvdHostScripts"]
    assert scripts["Seen"] == 0 and scripts["OutdatedHostnames"] == [] and scripts["Versions"] == []


def start_on_demand_row(**values):
    row = {"Result": "Updated", "Message": None, "StartOnDemandEnabled": True, "MaxPendingStarts": 4,
           "PreviousStartOnDemandEnabled": False, "PreviousMaxPendingStarts": 2, "ZeroMinimumCount": 0}
    row.update(values)
    return row


ADMIN_USER = {"roles": ["FullAccess"], "scp": "access_as_user", "oid": "oid-alice", "preferred_username": "alice@contoso.com"}


def test_start_on_demand_is_set_and_audited(auth_client, fake_db, audit_entries):
    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row()
    client = auth_client(ADMIN_USER)

    response = client.post("/api/scaling/policy/update", json={"startondemandenabled": True, "maxpendingstarts": 4},
                           headers=auth_client.headers)

    assert response.status_code == 200
    assert response.get_json() == {
        "Result": "Updated", "StartOnDemandEnabled": True, "MaxPendingStarts": 4, "ZeroMinimumCount": 0,
        "message": "Start on demand is on. Up to 4 hosts may start at once for waiting users.",
    }
    assert fake_db.latest_call("SetScalingPolicyStartOnDemand")["params"] == (True, 4, "alice@contoso.com")
    assert "SetScalingPolicyTimeZone" not in procs(fake_db) and fake_db.commits == 1
    [entry] = [entry for entry in audit_entries if entry["action"] == "scaling.policy_update"]
    assert json.loads(entry["detailJson"]) == {"result": "Updated", "startOnDemand": {"from": False, "to": True},
                                               "maxPendingStarts": {"from": 2, "to": 4}, "status": 200}


def test_one_setting_at_a_time_leaves_the_other_alone(client, fake_db):
    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row(MaxPendingStarts=3)
    client.post("/api/scaling/policy/update", json={"maxpendingstarts": "3"})
    assert fake_db.latest_call("SetScalingPolicyStartOnDemand")["params"][:2] == (None, 3)

    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row(
        StartOnDemandEnabled=False, PreviousStartOnDemandEnabled=True, ZeroMinimumCount=2)
    body = client.post("/api/scaling/policy/update", json={"startondemandenabled": False}).get_json()
    assert fake_db.latest_call("SetScalingPolicyStartOnDemand")["params"][:2] == (False, None)
    assert body["message"] == ("Start on demand is off. 2 scaling rules and windows have a minimum of 0, so scaling keeps "
                               "one host running for them.")

    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row(
        StartOnDemandEnabled=False, ZeroMinimumCount=0, Result="Unchanged")
    body = client.post("/api/scaling/policy/update", json={"startondemandenabled": False}).get_json()
    assert body["Result"] == "Unchanged"
    assert body["message"] == "Start on demand is off. A user who finds no ready host is refused."


def test_the_zone_and_start_on_demand_are_applied_together(client, fake_db):
    fake_db.fetchone_rows["SetScalingPolicyTimeZone"] = {"Result": "Unchanged", "TimeZone": "UTC", "PreviousTimeZone": "UTC"}
    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row(MaxPendingStarts=1)

    body = client.post("/api/scaling/policy/update",
                       json={"timezone": "UTC", "startondemandenabled": True, "maxpendingstarts": 1}).get_json()

    assert body["Result"] == "Updated" and body["TimeZone"] == "UTC"
    assert body["message"] == "Schedules were already read in UTC. Start on demand is on. Up to 1 host may start at once for waiting users."
    assert fake_db.commits == 1 and len(fake_db.connections) == 1


@pytest.mark.parametrize("payload,message", [
    ({}, "Provide timezone, startondemandenabled, maxpendingstarts, or any of them."),
    ({"startondemandenabled": "yes"}, "startondemandenabled must be true or false."),
    ({"maxpendingstarts": 0}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"maxpendingstarts": 21}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"maxpendingstarts": True}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"maxpendingstarts": 2.5}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"maxpendingstarts": "\u00b2"}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"maxpendingstarts": "9" * 5000}, "maxpendingstarts must be a whole number from 1 to 20."),
    ({"timezone": " ", "startondemandenabled": True}, "Provide the timezone as a name from /api/scaling/timezones."),
])
def test_invalid_policy_settings_are_refused_before_the_database(client, fake_db, payload, message):
    response = client.post("/api/scaling/policy/update", json=payload)
    assert response.status_code == 400 and response.get_json()["error"] == message
    assert fake_db.calls == []


def test_nothing_is_applied_when_any_part_is_refused(client, fake_db):
    fake_db.fetchone_rows["SetScalingPolicyTimeZone"] = {"Result": "InvalidTimeZone", "TimeZone": "UTC"}
    response = client.post("/api/scaling/policy/update", json={"timezone": "Mars", "startondemandenabled": True})
    assert response.status_code == 400 and "Mars" in response.get_json()["error"]
    assert "SetScalingPolicyStartOnDemand" not in procs(fake_db) and fake_db.commits == 0

    fake_db.fetchone_rows["SetScalingPolicyTimeZone"] = {"Result": "Updated", "TimeZone": "UTC", "PreviousTimeZone": "Tokyo Standard Time"}
    fake_db.fetchone_rows["SetScalingPolicyStartOnDemand"] = start_on_demand_row(
        Result="Invalid", Message="maxpendingstarts must be between 1 and 20.")
    response = client.post("/api/scaling/policy/update", json={"timezone": "UTC", "maxpendingstarts": 5})
    assert response.status_code == 400 and response.get_json()["error"] == "maxpendingstarts must be between 1 and 20."
    assert fake_db.commits == 0


def test_start_on_demand_needs_the_upgraded_database(client, fake_db):
    fake_db.raise_on_execute["SetScalingPolicyStartOnDemand"] = MISSING.format("SetScalingPolicyStartOnDemand")
    response = client.post("/api/scaling/policy/update", json={"startondemandenabled": True})
    assert response.status_code == 404
    assert response.get_json()["error"] == "Start on demand is not available until the database is upgraded."
    assert fake_db.commits == 0


# ------------------------------------------------------------------ schedules and the preview


SCHEDULE = {"name": "Nights", "days": ["mon"], "start": "20:00", "end": "23:00", "minvms": 0, "maxvms": 4,
            "scaleupratio": 60, "scaleupincrement": 1, "scaledownratio": 20, "scaledownincrement": 1}


def test_a_window_scales_to_zero_while_start_on_demand_is_on(client, fake_db):
    fake_db.fetchall_rows["GetScalingSchedules"] = []
    fake_db.fetchone_rows["GetScalingPolicy"] = policy_row()
    fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": "Created", "ScheduleID": 3}

    assert client.post("/api/scaling/schedules/create", json=SCHEDULE).status_code == 201
    assert fake_db.latest_call("SaveScalingSchedule")["params"][6] == 0


def test_the_preview_counts_waiting_users_and_checks_a_zero_minimum(client, fake_db):
    fake_db.fetchone_rows["TriggerScalingLogic"] = {
        "Action": "PowerOn", "RequestCount": 1, "CandidatesJson": json.dumps([{"Hostname": "lnx-09"}]),
        "Reason": "Serviceable hosts are below the minimum. 1 user is waiting for a host to start.", "PhaseSource": "Rule",
        "MinVMs": 0, "MaxVMs": 4, "PoweredOn": 0, "Serviceable": 0, "InUse": 0, "Draining": 0, "Utilization": 100,
        "Waiting": 1, "StartOnDemandEnabled": True,
    }

    body = client.get("/api/scaling/preview").get_json()
    assert body["Counts"]["Waiting"] == 1 and body["StartOnDemandEnabled"] is True

    fake_db.fetchone_rows["GetScalingPolicy"] = policy_row(StartOnDemandEnabled=False)
    proposed = {key: value for key, value in SCHEDULE.items() if key not in ("days", "start", "end")}
    response = client.post("/api/scaling/preview", json={"rule": proposed})
    assert response.status_code == 400
    assert response.get_json()["error"] == "minvms can be 0 only while start on demand is on."
