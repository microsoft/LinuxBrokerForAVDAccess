from function_api import (
    build_history_payload,
    filters_from_args,
    pagination_from_args,
    summarize_vms,
    validate_history_filters,
)


def test_summarize_vms_empty_and_none_are_safe():
    for value in (None, []):
        summary = summarize_vms(value)
        assert summary["total"] == 0
        assert summary["utilization"] == 0
        assert all(percent == 0 for percent in summary["pct"].values())


def test_summarize_vms_ready_requires_available_on_reachable():
    vms = [
        {"VmStatus": "Available", "PowerState": "On", "NetworkStatus": "Reachable"},
        {"VmStatus": "Available", "PowerState": "Off", "NetworkStatus": "Reachable"},
        {"VmStatus": "Available", "PowerState": "On", "NetworkStatus": "Unreachable"},
        {"VmStatus": "CheckedOut", "PowerState": "On", "NetworkStatus": "Reachable"},
        None,
    ]
    summary = summarize_vms(vms)
    assert summary["total"] == 5
    assert summary["ready"] == 1
    assert summary["available"] == 3
    assert summary["checked_out"] == 1
    assert summary["powered_on"] == 3
    assert summary["unreachable"] == 1
    assert summary["utilization"] == 20


# --------------------------------------------------- history filter helpers


def test_filters_from_args_reads_the_query_string():
    filters = filters_from_args({
        "startdate": " 2026-01-15 ",
        "enddate": "2026-02-20",
        "limit": "37",
        "ignore_dates": "1",
        "ignore_limit": "true",
    })

    assert filters["startdate"] == "2026-01-15"
    assert filters["limit"] == "37"
    assert filters["ignore_dates"] is True
    assert filters["ignore_limit"] is True


def test_filters_from_args_defaults_to_an_unfiltered_view():
    filters = filters_from_args({})

    assert filters == {"startdate": "", "enddate": "", "limit": "",
                       "ignore_dates": False, "ignore_limit": False}


def test_only_recognised_truthy_values_set_an_ignore_flag():
    for value in ("1", "true", "TRUE", "yes", "on"):
        assert filters_from_args({"ignore_dates": value})["ignore_dates"] is True
    for value in ("0", "false", "no", "off", ""):
        assert filters_from_args({"ignore_dates": value})["ignore_dates"] is False


def test_validate_history_filters_accepts_iso_dates():
    assert validate_history_filters({"startdate": "2026-01-15", "enddate": "2026-02-20"}) is None


def test_validate_history_filters_names_the_offending_end():
    error = validate_history_filters({"startdate": "15-01-2026"})
    assert "start" in error and "YYYY-MM-DD" in error

    error = validate_history_filters({"enddate": "not-a-date"})
    assert "end" in error


def test_validate_history_filters_skips_validation_when_dates_are_ignored():
    assert validate_history_filters({"startdate": "nonsense", "ignore_dates": True}) is None


def test_build_history_payload_converts_to_the_stored_procedure_format():
    payload = build_history_payload({"startdate": "2026-01-15", "enddate": "2026-02-20",
                                     "limit": "37"})

    assert payload["startdate"] == "01/15/2026"
    assert payload["enddate"] == "02/20/2026"
    assert payload["limit"] == 37


def test_build_history_payload_honours_the_ignore_flags():
    payload = build_history_payload({"startdate": "2026-01-15", "enddate": "2026-02-20",
                                     "limit": "37", "ignore_dates": True, "ignore_limit": True})
    assert payload == {}


def test_build_history_payload_drops_an_unparseable_limit_rather_than_failing():
    payload = build_history_payload({"limit": "many"})
    assert payload == {}


# ------------------------------------------------------------- pagination


def test_pagination_defaults():
    assert pagination_from_args({}) == (1, 10)


def test_pagination_clamps_hostile_values():
    assert pagination_from_args({"page": "abc"}) == (1, 10)
    assert pagination_from_args({"page": "0"}) == (1, 10)
    assert pagination_from_args({"page": "-5"}) == (1, 10)
    assert pagination_from_args({"per_page": "-3"}) == (1, 1)
    assert pagination_from_args({"per_page": "abc"}) == (1, 10)


def test_pagination_caps_per_page_so_one_request_cannot_pull_everything():
    assert pagination_from_args({"per_page": "100000"}) == (1, 200)
