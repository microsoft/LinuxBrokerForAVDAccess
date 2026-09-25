"""BFF endpoints for 2.7 the host list and import."""

import pytest

from conftest import API, post
from function_api import page_vms_locally


def test_the_bare_list_is_unchanged_without_paging(signed_in_client, broker_api):
    body = signed_in_client.get(f"{API}/vms").get_json()
    assert isinstance(body, list) and len(body) == 4
    assert broker_api.gets[-1]["params"] is None


def test_a_page_is_asked_of_the_broker_and_passed_through(signed_in_client, broker_api):
    page = {"items": [{"Hostname": "linux-host-02"}], "page": 2, "per_page": 25, "total": 26, "total_pages": 2,
            "counts": {"all": 26}, "status": "in-use", "sort": "heartbeat", "dir": "desc"}
    broker_api.get_replies["/vms"] = (200, page)

    body = signed_in_client.get(f"{API}/vms?page=2&per_page=25&q=%20linux%20&status=in-use&sort=heartbeat&dir=desc").get_json()

    assert body == page
    assert broker_api.gets[-1]["params"] == {"page": 2, "per_page": 25, "q": "linux", "status": "in-use", "sort": "heartbeat", "dir": "desc"}


def test_unknown_filters_fall_back_to_safe_values(signed_in_client, broker_api):
    broker_api.get_replies["/vms"] = (200, {"items": []})
    signed_in_client.get(f"{API}/vms?status=bogus&sort=password&dir=sideways&per_page=9999")
    assert broker_api.gets[-1]["params"] == {"page": 1, "per_page": 200, "status": "all", "sort": "hostname", "dir": "asc"}


def test_an_older_api_is_paged_in_the_portal(signed_in_client, broker_api):
    body = signed_in_client.get(f"{API}/vms?page=1&per_page=2&status=all&sort=vmid&dir=desc").get_json()

    assert body["legacy"] is True
    assert [item["Hostname"] for item in body["items"]] == ["linux-host-04", "linux-host-03"]
    assert (body["total"], body["total_pages"]) == (4, 2)
    assert body["counts"] == {"all": 4, "ready": 1, "in-use": 1, "released": 1, "maintenance": 1, "draining": 0,
                              "unreachable": 0, "off": 1, "cleanup": 0}


@pytest.mark.parametrize("params,expected", [
    ({"status": "ready"}, ["linux-host-01"]),
    ({"status": "off"}, ["linux-host-03"]),
    ({"q": "BOB"}, ["linux-host-04"]),
    ({"q": "10.0.0.5"}, ["linux-host-02"]),
    ({"sort": "user", "dir": "asc"}, ["linux-host-02", "linux-host-04", "linux-host-01", "linux-host-03"]),
    ({"sort": "os"}, ["linux-host-01", "linux-host-02", "linux-host-03", "linux-host-04"]),
])
def test_local_paging_filters_searches_and_sorts(params, expected):
    from conftest import VMS
    base = {"page": 1, "per_page": 50, "status": "all", "sort": "hostname", "dir": "asc"}
    result = page_vms_locally(VMS, dict(base, **params))
    assert [item["Hostname"] for item in result["items"]] == expected
    assert all("LeaseId" not in item for item in result["items"])


def test_import_candidates_are_read_through_with_a_long_timeout(signed_in_client, broker_api):
    broker_api.get_replies["/vms/import/candidates"] = (200, {"Candidates": [{"Hostname": "lnx-new", "Importable": True}]})
    body = signed_in_client.get(f"{API}/vms/import/candidates").get_json()
    assert body["Candidates"][0]["Hostname"] == "lnx-new"
    assert broker_api.gets[-1]["timeout"] == 90


def test_hosts_are_imported_by_name(signed_in_client, broker_api):
    broker_api.post_replies["/vms/import"] = (200, {"Imported": 1, "Results": [], "message": "Imported 1 of 1 host."})
    response = post(signed_in_client, f"{API}/vms/import", {"hostnames": ["lnx-new"], "ip": "10.9.9.9"})
    assert response.status_code == 200 and response.get_json()["Imported"] == 1
    assert broker_api.posts[-1]["json"] == {"hostnames": ["lnx-new"]}


@pytest.mark.parametrize("payload", [{}, {"hostnames": []}, {"hostnames": ["bad host"]}, {"hostnames": ["h"] * 101}])
def test_an_unusable_import_never_reaches_the_broker(signed_in_client, broker_api, payload):
    response = post(signed_in_client, f"{API}/vms/import", payload)
    assert response.status_code == 400
    assert not any(call["url"].endswith("/vms/import") for call in broker_api.posts)
