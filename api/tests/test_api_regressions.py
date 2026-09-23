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
    assert fake_db.connections
    assert all(connection.closed for connection in fake_db.connections)


@pytest.mark.parametrize("path,method,proc", [
    ("/api/vms", "get", "GetVms"),
    ("/api/vms/summary", "get", "GetVmSummary"),
    ("/api/scaling/rules", "get", "GetScalingRules"),
    ("/api/scaling/log", "post", "GetScalingActivityLog"),
])
def test_database_errors_do_not_disclose_driver_details(client, fake_db, path, method, proc):
    detail = "pymssql: login failed for user sa at db-prod-01"
    fake_db.raise_on_execute[proc] = detail
    response = getattr(client, method)(path, json={})
    assert response.status_code == 500
    assert detail not in response.get_data(as_text=True)
    assert "db-prod-01" not in response.get_data(as_text=True)
    assert response.get_json()["error"]


def test_vm_summary_returns_integer_zeroes_when_procedure_has_no_row(client, fake_db):
    fake_db.fetchone_rows["GetVmSummary"] = None
    response = client.get("/api/vms/summary")
    assert response.status_code == 200
    assert response.get_json() == {
        "TotalVMs": 0, "Available": 0, "CheckedOut": 0, "Maintenance": 0, "Released": 0,
        "PoweredOn": 0, "PoweredOff": 0, "Unreachable": 0, "Ready": 0,
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
    assert response.get_json()["page"] == page
    assert response.get_json()["per_page"] == per_page
    assert fake_db.latest_call("GetVmHistoryPaged")["params"] == (None, None, offset, size)


@pytest.mark.parametrize("path,_proc,paged_proc", HISTORY_ENDPOINTS)
def test_paged_history_reports_the_total_on_an_out_of_range_page(client, fake_db, path, _proc, paged_proc):
    fake_db.fetchall_sequence[paged_proc] = [[], [{"VMID": 1, "TotalCount": 37}]]
    response = client.post(f"{path}?page=40&per_page=10", json={})
    assert response.status_code == 200
    body = response.get_json()
    assert body["items"] == []
    assert body["total"] == 37
    assert body["total_pages"] == 4
    assert body["page"] == 40


def test_trigger_scaling_logic_commits_its_transaction(client, fake_db):
    before = fake_db.commits
    response = client.post("/api/scaling/trigger", json={})
    assert response.status_code < 500
    assert fake_db.commits > before


def test_regression_client_preserves_policy_wrappers(client, app_module):
    assert app_module.app.view_functions["get_all_vms"].authorization_policy is app_module.Policy.INVENTORY
    assert client.post("/api/vms/checkout", json={"avdhost": "avd-01"}).status_code == 403
