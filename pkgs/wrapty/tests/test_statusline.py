"""The statusline's rendering, which is pure and therefore cheap to pin.

Every field Claude Code reports is optional: an API key has no plan windows,
and an older Claude Code reports neither them nor the cost. The line has to
render whatever it gets.
"""

import pytest

import wrapty_statusline as sl

NOW = 1_000_000.0


@pytest.mark.parametrize(
    "seconds, expected",
    [
        (-60, "now"),
        (0, "now"),
        (40 * 60, "40m"),
        (3 * 3600, "3h"),
        (2 * 86400, "2d"),
        (3599, "59m"),
        (86399, "23h"),
    ],
)
def test_until_picks_one_unit(seconds, expected):
    assert sl._until(NOW + seconds, NOW) == expected


def test_a_quiet_window_omits_its_reset():
    window = sl._window({"used_percentage": 62, "resets_at": NOW + 3600}, "5h", NOW)
    assert window == "5h 62%"


def test_a_loud_window_shows_its_reset():
    window = sl._window({"used_percentage": 91, "resets_at": NOW + 3600}, "5h", NOW)
    assert window == "5h 91% (1h)"


def test_a_loud_window_without_a_reset_time_stays_quiet():
    assert sl._window({"used_percentage": 91}, "5h", NOW) == "5h 91%"


@pytest.mark.parametrize("data", [None, {}, {"resets_at": NOW}])
def test_a_window_with_no_percentage_is_omitted(data):
    assert sl._window(data, "5h", NOW) is None


def test_a_full_payload_renders_every_part_in_order():
    payload = {
        "model": {"display_name": "Opus 5"},
        "context_window": {"used_percentage": 41},
        "rate_limits": {
            "five_hour": {"used_percentage": 88, "resets_at": NOW + 7200},
            "seven_day": {"used_percentage": 12},
        },
        "cost": {"total_cost_usd": 3.456},
    }
    assert sl._render(payload, NOW) == "Opus 5 · ctx 41% · 5h 88% (2h) · 7d 12% · $3.46"


def test_an_empty_payload_still_renders():
    assert sl._render({}, NOW) == "?"


def test_missing_plan_windows_are_skipped():
    payload = {
        "model": {"display_name": "Opus 5"},
        "context_window": {"used_percentage": 7},
        "cost": {"total_cost_usd": 0},
    }
    assert sl._render(payload, NOW) == "Opus 5 · ctx 7% · $0.00"
