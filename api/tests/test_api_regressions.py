import pytest


HISTORY_ENDPOINTS = [
    ("/api/vms/history", "GetVmHistory", "GetVmHistoryPaged"),
    ("/api/scaling/log", "GetScalingActivityLog", "GetScalingActivityLogPaged"),
    ("/api/scaling/rules/history", "GetVMScalingRulesHistory", "GetVmScalingRulesHistoryPaged"),
]


def test_coerce_optional_int_handles_nullish_junk_and_clamps(app_module):
    coerce = app_module.coerce_optional_int
    for value in (None, "", "  ", "null", "NULL", "none", "undefined", "not-an-int", True):
        assert coerce(value, default=None, minimum=1, maximum=200) is None
    assert coerce("5", minimum=1, maximum=200) == 5
    assert coerce("0", minimum=1, maximum=200) == 1
    assert coerce("999", minimum=1, maximum=200) == 200


@pytest.mark.parametrize("path,proc,_paged_proc", HISTORY_ENDPOINTS)
def test_history_null_limit_is_omitted_for_unpaged_queries(client, fake_db, path, proc, _paged_proc):
    response = client.post(path, json={"startdate": "null", "enddate": "", "limit": "null"})
    assert response.status_code == 200
    assert response.get_json() == fake_db.fetchall_rows[proc]
    assert fake_db.latest_call(proc)["params"] == (None, None, None)


@pytest.mark.parametrize("path,proc,_paged_proc", HISTORY_ENDPOINTS)
def test_history_unparseable_and_low_limit_are_safe(client, fake_db, path, proc, _paged_proc):
    response = client.post(path, json={"limit": "junk"})
    assert response.status_code == 200
    assert fake_db.latest_call(proc)["params"][2] is None

    response = client.post(path, json={"limit": "0"})
    assert response.status_code == 200
    assert fake_db.latest_call(proc)["params"][2] == 1


@pytest.mark.parametrize("path,proc", [
    ("/api/scaling/rules", "GetScalingRules"),
    ("/api/scaling/log", "GetScalingActivityLog"),
    ("/api/scaling/rules/history", "GetVMScalingRulesHistory"),
])
def test_empty_collection_contracts_are_200_json_arrays(client, fake_db, path, proc):
    fake_db.fetchall_rows[proc] = []
    response = client.get(path) if path == "/api/scaling/rules" else client.post(path, json={})
    assert response.status_code == 200
    assert response.is_json
    assert response.get_json() == []


@pytest.mark.parametrize("path,proc", [
    ("/api/vms", "GetVms"),
    ("/api/scaling/rules", "GetScalingRules"),
    ("/api/scaling/log", "GetScalingActivityLog"),
])
def test_connection_closes_when_cursor_execute_raises(client, fake_db, path, proc):
    fake_db.raise_on_execute[proc] = "forced cursor failure"
    response = client.get(path) if path in {"/api/vms", "/api/scaling/rules"} else client.post(path, json={})
    assert response.status_code == 500
    assert fake_db.connections, "expected the handler to open a connection"
    assert all(connection.closed for connection in fake_db.connections)


@pytest.mark.parametrize("path,method,proc", [
    ("/api/vms", "get", "GetVms"),
    ("/api/vms/summary", "get", "GetVmSummary"),
    ("/api/scaling/rules", "get", "GetScalingRules"),
    ("/api/scaling/log", "post", "GetScalingActivityLog"),
])
def test_database_errors_do_not_disclose_driver_details(client, fake_db, path, method, proc):
    secret = "pymssql: login failed for user sa at db-prod-01"
    fake_db.raise_on_execute[proc] = secret
    response = getattr(client, method)(path, json={})
    assert response.status_code == 500
    body = response.get_data(as_text=True)
    assert secret not in body
    assert "db-prod-01" not in body
    assert response.get_json()["error"]


def test_vm_summary_returns_integer_zeroes_when_procedure_has_no_row(client, fake_db):
    fake_db.fetchone_rows["GetVmSummary"] = None
    response = client.get("/api/vms/summary")
    assert response.status_code == 200
    assert response.get_json() == {
        "TotalVMs": 0,
        "Available": 0,
        "CheckedOut": 0,
        "Maintenance": 0,
        "Released": 0,
        "PoweredOn": 0,
        "PoweredOff": 0,
        "Unreachable": 0,
        "Ready": 0,
    }
    assert all(isinstance(value, int) for value in response.get_json().values())


@pytest.mark.parametrize("path,_proc,paged_proc", HISTORY_ENDPOINTS)
def test_history_pagination_is_opt_in_and_strips_total_count(client, fake_db, path, _proc, paged_proc):
    unpaged = client.post(path, json={})
    assert unpaged.status_code == 200
    assert isinstance(unpaged.get_json(), list)

    paged = client.post(f"{path}?page=2&per_page=2", json={})
    assert paged.status_code == 200
    payload = paged.get_json()
    assert set(payload) == {"items", "page", "per_page", "total", "total_pages"}
    assert payload["page"] == 2
    assert payload["per_page"] == 2
    assert payload["total"] == fake_db.fetchall_rows[paged_proc][0]["TotalCount"]
    assert all("TotalCount" not in item for item in payload["items"])
    assert fake_db.latest_call(paged_proc)["params"] == (None, None, 2, 2)


@pytest.mark.parametrize("query,expected", [
    ("page=abc", (1, 50, 0, 50)),
    ("per_page=999", (1, 200, 0, 200)),
    ("page=0&per_page=-3", (1, 1, 0, 1)),
])
def test_history_pagination_coerces_hostile_values(client, fake_db, query, expected):
    page, per_page, offset, size = expected
    response = client.post(f"/api/vms/history?{query}", json={})
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["page"] == page
    assert payload["per_page"] == per_page
    assert fake_db.latest_call("GetVmHistoryPaged")["params"] == (None, None, offset, size)


class _JwksResponse:
    status_code = 200

    def json(self):
        return {"keys": [{"kid": "test-kid", "kty": "RSA", "use": "sig", "n": "n", "e": "e"}]}


def _call_token_required(app_module, monkeypatch, payload=None, decode_exception=None, header="Bearer token", group_member=True):
    monkeypatch.setattr(app_module.requests, "get", lambda url: _JwksResponse())
    monkeypatch.setattr(app_module.jwt, "get_unverified_header", lambda token: {"kid": "test-kid"})

    observed = {}

    def fake_decode(token, key, algorithms, audience, issuer):
        observed["audience"] = audience
        observed["issuer"] = issuer
        if decode_exception:
            raise decode_exception
        return payload if payload is not None else {"oid": "user-oid", "scp": "Allowed"}

    monkeypatch.setattr(app_module.jwt, "decode", fake_decode)
    monkeypatch.setattr(app_module, "is_member_of_group", lambda oid, groups: group_member and "matching-group" in groups)

    def protected():
        return app_module.jsonify({"ok": True}), 200

    wrapped = app_module.token_required(["Allowed"], required_group_ids=["matching-group"])(protected)
    headers = {"Authorization": header} if header is not None else {}
    with app_module.app.test_request_context("/protected", headers=headers):
        result = wrapped()
    return result, observed


@pytest.mark.parametrize("payload", [
    {"oid": "user-oid", "scp": "Allowed Other"},
    {"oid": "user-oid", "roles": ["Allowed"]},
])
def test_token_required_accepts_matching_scope_or_role(app_module, monkeypatch, payload):
    result, observed = _call_token_required(app_module, monkeypatch, payload=payload, group_member=False)
    response, status = result
    assert status == 200
    assert response.get_json() == {"ok": True}
    assert observed["audience"] == [app_module.CLIENT_ID, app_module.APP_URI]
    assert observed["issuer"] == [
        f"{app_module.AUTHORITY_HOST}/{app_module.TENANT_ID}/v2.0",
        f"{app_module.AUTHORITY_HOST}/{app_module.TENANT_ID}/",
        f"{app_module.STS_ISSUER_HOST}/{app_module.TENANT_ID}/",
    ]


@pytest.mark.parametrize("exception_cls,message", [
    ("ExpiredSignatureError", "Token has expired."),
    ("InvalidAudienceError", "Invalid audience."),
    ("InvalidIssuerError", "Invalid issuer."),
])
def test_token_required_rejects_expired_wrong_audience_and_wrong_issuer(app_module, monkeypatch, exception_cls, message):
    exc = getattr(app_module.jwt, exception_cls)("boom")
    result, _observed = _call_token_required(app_module, monkeypatch, decode_exception=exc)
    response, status = result
    assert status == 401
    assert response.get_json() == {"message": message}


@pytest.mark.parametrize("header", [None, "", "Basic token", "Bearer", "Bearer one two"])
def test_token_required_rejects_missing_or_malformed_authorization(app_module, monkeypatch, header):
    result, _observed = _call_token_required(app_module, monkeypatch, header=header)
    response, status = result
    assert status == 401
    assert response.get_json() == {"message": "Token is missing!"}


def test_token_required_rejects_token_without_oid(app_module, monkeypatch):
    result, _observed = _call_token_required(app_module, monkeypatch, payload={"scp": "Allowed"})
    response, status = result
    assert status == 403
    assert response.get_json() == {"message": "Token does not contain user ID (oid)."}


def test_token_required_rejects_insufficient_scope_role_and_group(app_module, monkeypatch):
    result, _observed = _call_token_required(
        app_module,
        monkeypatch,
        payload={"oid": "user-oid", "scp": "Other", "roles": ["Different"]},
        group_member=False,
    )
    response, status = result
    assert status == 403
    assert "Access denied" in response.get_json()["message"]





# ---------------------------------------------------------------------------
# Regressions found in code review of the hardening change itself.


@pytest.mark.parametrize("path,_proc,paged_proc", HISTORY_ENDPOINTS)
def test_paged_history_reports_the_total_on_an_out_of_range_page(client, fake_db, path, _proc, paged_proc):
    """A page past the end must still report the real total.

    TotalCount rides along on each row, so an empty page would otherwise report
    total=0, making "page 40 of 4" indistinguishable from "no matches" and
    collapsing the pager so the operator cannot navigate back.
    """
    fake_db.fetchall_sequence[paged_proc] = [
        [],                                     # the requested, out-of-range page
        [{"VMID": 1, "TotalCount": 37}],        # the probe that recovers the total
    ]

    response = client.post(f"{path}?page=40&per_page=10", json={})
    assert response.status_code == 200

    body = response.get_json()
    assert body["items"] == []
    assert body["total"] == 37
    assert body["total_pages"] == 4
    assert body["page"] == 40


def test_trigger_scaling_logic_commits_its_transaction(client, fake_db):
    """TriggerScalingLogic updates PowerState and inserts the activity-log row.

    pymssql does not autocommit, so without an explicit commit the database rolled
    all of that back while the Azure power operations still went ahead.
    """
    before = fake_db.commits
    response = client.post("/api/scaling/trigger", json={})
    assert response.status_code < 500
    assert fake_db.commits > before, "TriggerScalingLogic ran without committing"


def test_group_check_failure_is_not_cached_as_a_denial(app_module, monkeypatch):
    """A Graph outage must surface as a dependency failure, not a 403.

    is_member_of_group returns False for "not a member" but raises
    GroupCheckUnavailable when it cannot tell. If the unavailable case were returned
    as False it would be memoized for the whole cache window, locking every AVD
    checkout and Linux host release out for five minutes.
    """
    app_module.cache.clear()
    calls = {"n": 0}

    def exploding_graph(oid, groups):
        calls["n"] += 1
        raise app_module.GroupCheckUnavailable("Graph API returned 429.")

    monkeypatch.setattr(app_module, "is_member_of_group", exploding_graph)
    monkeypatch.setattr(app_module.requests, "get", lambda url: _JwksResponse())
    monkeypatch.setattr(app_module.jwt, "get_unverified_header", lambda token: {"kid": "test-kid"})
    monkeypatch.setattr(app_module.jwt.algorithms.RSAAlgorithm, "from_jwk", staticmethod(lambda key: "key"))
    monkeypatch.setattr(app_module.jwt, "decode", lambda *a, **k: {"oid": "user-oid"})

    def protected():
        return app_module.jsonify({"ok": True}), 200

    wrapped = app_module.token_required(["Allowed"], required_group_ids=["matching-group"])(protected)

    statuses = []
    for _ in range(2):
        with app_module.app.test_request_context("/protected", headers={"Authorization": "Bearer t"}):
            _, status = wrapped()
            statuses.append(status)

    # Reported as unavailable, not as a permissions denial.
    assert statuses == [503, 503]
    # And retried rather than served from the memo cache.
    assert calls["n"] == 2


def test_is_member_of_group_raises_rather_than_denying_on_graph_failure(app_module, monkeypatch):
    """The function itself must distinguish "not a member" from "could not tell".

    Returning False on a Graph 429 would be memoized by is_member_of_group_cached and
    served as an authorization denial for the whole cache window.
    """
    class _Throttled:
        status_code = 429
        text = "throttled"

        def json(self):
            return {}

    monkeypatch.setattr(app_module, "get_access_token", lambda *a, **k: "graph-token")
    monkeypatch.setattr(app_module.requests, "post", lambda *a, **k: _Throttled())

    with pytest.raises(app_module.GroupCheckUnavailable):
        app_module.is_member_of_group("user-oid", ["group-a"])


def test_is_member_of_group_raises_when_no_graph_token(app_module, monkeypatch):
    monkeypatch.setattr(app_module, "get_access_token", lambda *a, **k: None)
    with pytest.raises(app_module.GroupCheckUnavailable):
        app_module.is_member_of_group("user-oid", ["group-a"])


def test_is_member_of_group_still_returns_false_for_a_real_non_member(app_module, monkeypatch):
    """The genuine "not a member" answer must stay a plain False so it can be cached."""
    class _Ok:
        status_code = 200
        text = "{}"

        def json(self):
            return {"value": []}

    monkeypatch.setattr(app_module, "get_access_token", lambda *a, **k: "graph-token")
    monkeypatch.setattr(app_module.requests, "post", lambda *a, **k: _Ok())

    assert app_module.is_member_of_group("user-oid", ["group-a"]) is False
