"""2.10 broadcast messages: who is messaged, in parallel and bounded, and what is reported."""

import json
import types

import pytest


OPERATOR_USER = {"roles": ["Operator"], "scp": "access_as_user", "oid": "oid-olga", "preferred_username": "olga@contoso.com"}
DELIVERED = "__SESSION_CONTROL_RESULT=delivered\n__SESSION_CONTROL_SESSIONS={n}\n__SESSION_CONTROL_DELIVERED={n}\n"


def vm(hostname, power="On", network="Reachable", username=None):
    return {"VMID": 1, "Hostname": hostname, "PowerState": power, "NetworkStatus": network, "VmStatus": "Available", "Username": username}


def session(hostname, username, state="active", has_assignment=True, cleanup=False):
    return {
        "VMID": 1, "Hostname": hostname, "Username": username, "AvdHost": None, "VmStatus": "CheckedOut",
        "PowerState": "On", "NetworkStatus": "Reachable", "DrainRequested": False, "HasAssignment": has_assignment,
        "BrokerTracked": has_assignment or cleanup, "CleanupPending": cleanup,
        "SessionState": state if state in ("active", "disconnected") else None,
        "SessionStartEpoch": None, "DisconnectedForSeconds": None, "IdleSeconds": None, "AssignedForSeconds": None,
        "LastCheckoutAgeSeconds": 600, "GraceRemainingSeconds": None, "HeartbeatAgeSeconds": 20,
        "GracePeriodSeconds": 1200, "ReconcileIntervalSeconds": 60,
    }


class Hosts:
    """Answers message-all per host: a stdout string, or an exception to raise."""

    def __init__(self, replies=None, default=DELIVERED.format(n=1)):
        self.calls = []
        self.replies = replies or {}
        self.default = default

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        self.calls.append({"hostname": hostname, "command": command, "stdin": stdin_input, "timeout": timeout})
        reply = self.replies.get(hostname, self.default)
        if isinstance(reply, Exception):
            raise reply
        if isinstance(reply, tuple):
            returncode, stdout, stderr = reply
        else:
            returncode, stdout, stderr = 0, reply, ""
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr), f"avdadmin@{hostname}"


@pytest.fixture
def hosts(app_module, monkeypatch):
    fake = Hosts()
    monkeypatch.setattr(app_module, "run_remote_command", fake)
    return fake


def test_a_broadcast_reaches_every_host_someone_is_using(client, fake_db, hosts):
    fake_db.fetchall_rows["GetVms"] = [
        vm("lnx-01"), vm("lnx-02"), vm("lnx-03"), vm("lnx-04", power="Off", network="Unreachable"), vm("lnx-05"),
    ]
    fake_db.fetchall_rows["GetSessions"] = [
        session("lnx-01", "alice"),
        session("lnx-02", "mallory", has_assignment=False),
        session("lnx-04", "bob"),
        session("lnx-05", "carol", state=None, has_assignment=False, cleanup=True),
    ]
    hosts.replies["lnx-02"] = DELIVERED.format(n=2)

    body = client.post("/api/sessions/broadcast", json={"message": "Restarting at 18:00"}).get_json()

    assert sorted(call["hostname"] for call in hosts.calls) == ["lnx-01", "lnx-02"]
    assert all(call["command"] == "sudo -n /usr/local/bin/session-control.sh message-all" for call in hosts.calls)
    assert all(call["stdin"] == "Restarting at 18:00" for call in hosts.calls)
    assert all(call["timeout"] == 20 for call in hosts.calls)
    assert body["TargetCount"] == 2 and body["Delivered"] == 3
    assert body["message"] == "Shown in 3 session(s) on 2 of 2 host(s)."


def test_a_broadcast_to_named_hosts_skips_what_it_cannot_reach(client, fake_db, hosts):
    fake_db.fetchall_rows["GetVms"] = [vm("lnx-01"), vm("lnx-02", power="Off", network="Unreachable")]

    body = client.post("/api/sessions/broadcast", json={"message": "Hello", "hostnames": ["LNX-01", "lnx-02", "ghost"]}).get_json()

    assert [call["hostname"] for call in hosts.calls] == ["lnx-01"]
    assert body["UnknownHostnames"] == ["ghost"] and body["SkippedHostnames"] == ["lnx-02"]
    assert "GetSessions" not in [call["proc"] for call in fake_db.calls]
    assert "Skipped 1 host(s)" in body["message"]


def test_a_broadcast_reports_hosts_it_could_not_reach(client, fake_db, hosts):
    fake_db.fetchall_rows["GetVms"] = [vm("lnx-01"), vm("lnx-02"), vm("lnx-03")]
    hosts.replies.update({
        "lnx-02": (1, "", "sudo: a password is required\n"),
        "lnx-03": RuntimeError("ssh: connect to host lnx-03 port 22: Connection timed out"),
    })

    body = client.post("/api/sessions/broadcast", json={"message": "Hello", "hostnames": ["lnx-01", "lnx-02", "lnx-03"]}).get_json()

    results = {entry["Hostname"]: entry["Result"] for entry in body["Results"]}
    assert results == {"lnx-01": "Delivered", "lnx-02": "AgentOutdated", "lnx-03": "Failed"}
    assert body["Delivered"] == 1
    assert "Not delivered to lnx-02, lnx-03" in body["message"]
    # The SSH error never reaches the response.
    assert "timed out" not in json.dumps(body)


def test_a_broadcast_stops_starting_hosts_at_the_deadline(app_module, client, fake_db, hosts, monkeypatch):
    fake_db.fetchall_rows["GetVms"] = [vm("lnx-01"), vm("lnx-02")]
    monkeypatch.setattr(app_module, "BROADCAST_DEADLINE_SECONDS", -1)

    body = client.post("/api/sessions/broadcast", json={"message": "Hello", "hostnames": ["lnx-01", "lnx-02"]}).get_json()

    assert hosts.calls == [] and body["NotAttempted"] == ["lnx-01", "lnx-02"]
    assert "2 host(s) were not reached" in body["message"]


@pytest.mark.parametrize("payload", [
    {},
    {"message": "   "},
    {"message": "x" * 501},
    {"message": "Hello", "hostnames": "lnx-01"},
    {"message": "Hello", "hostnames": []},
    {"message": "Hello", "hostnames": ["bad host"]},
    {"message": "Hello", "hostnames": [f"h{i}" for i in range(501)]},
])
def test_a_broadcast_is_validated_first(client, fake_db, hosts, payload):
    assert client.post("/api/sessions/broadcast", json=payload).status_code == 400
    assert fake_db.calls == [] and hosts.calls == []


def test_nothing_to_message_is_not_an_error(client, fake_db, hosts):
    fake_db.fetchall_rows["GetVms"] = [vm("lnx-01")]
    fake_db.fetchall_rows["GetSessions"] = []
    body = client.post("/api/sessions/broadcast", json={"message": "Hello"}).get_json()
    assert body["TargetCount"] == 0 and "nothing was sent" in body["message"]


def test_a_broadcast_is_audited_with_the_message(auth_client, fake_db, hosts, audit_entries):
    fake_db.fetchall_rows["GetVms"] = [vm("lnx-01")]
    client = auth_client(OPERATOR_USER)

    response = client.post("/api/sessions/broadcast", json={"message": "Patching tonight", "hostnames": ["lnx-01"]},
                           headers=auth_client.headers)

    assert response.status_code == 200
    [entry] = audit_entries
    assert entry["action"] == "session.broadcast" and entry["targetType"] == "fleet"
    detail = json.loads(entry["detailJson"])
    assert detail["message"] == "Patching tonight" and detail["delivered"] == 1 and detail["hostnames"] == ["lnx-01"]


def test_readers_cannot_broadcast(auth_client, fake_db):
    client = auth_client({"roles": ["Reader"], "scp": "access_as_user"})
    assert client.post("/api/sessions/broadcast", json={"message": "Hi"}, headers=auth_client.headers).status_code == 403
