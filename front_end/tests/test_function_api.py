from function_api import summarize_vms


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
