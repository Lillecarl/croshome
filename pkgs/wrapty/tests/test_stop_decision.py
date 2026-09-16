"""One Stop event, five possible meanings.

The nudge is what keeps a session working, so the interesting cases are the
ones that turn it off: each must be the right kind of off. A permitted stop is
spent once. A stop taken while background work runs is not spent at all, and
must not eat that permission either -- that leak is what put a need_user()
from one turn onto some unrelated stop several turns later.
"""

import os

from wrapty import wrapper as wrapty


def state(**overrides):
    base = {
        "allow_stop": False,
        "resume": None,
        "stop_count": 0,
        "cooldowns": {},
        "pending_compact": None,
        "monitors": {},
        "transcript_path": None,
        "task": None,
    }
    base.update(overrides)
    return base


def task(description="a build"):
    return {"id": "b1", "kind": "command", "description": description, "deadline": 0}


def test_an_ordinary_stop_is_nudged_and_counted():
    nudge_state = state()
    assert wrapty._stop_decision(nudge_state, []) == (wrapty.STOP_NUDGE, 1)
    assert wrapty._stop_decision(nudge_state, []) == (wrapty.STOP_NUDGE, 2)


def test_a_permitted_stop_is_spent_by_one_stop():
    nudge_state = state(allow_stop=True, stop_count=3)
    assert wrapty._stop_decision(nudge_state, [])[0] == wrapty.STOP_ALLOW
    assert nudge_state["stop_count"] == 0
    assert wrapty._stop_decision(nudge_state, [])[0] == wrapty.STOP_NUDGE


def test_running_work_suppresses_the_nudge():
    nudge_state = state(stop_count=2)
    action, waiting = wrapty._stop_decision(nudge_state, [task()])
    assert action == wrapty.STOP_WAIT
    assert waiting[0]["description"] == "a build"
    assert nudge_state["stop_count"] == 0


def test_running_work_suppresses_every_stop_not_just_one():
    nudge_state = state()
    for _ in range(3):
        assert wrapty._stop_decision(nudge_state, [task()])[0] == wrapty.STOP_WAIT


def test_a_registered_monitor_suppresses_it_the_same_way():
    nudge_state = state(monitors={"inbox:1": {"until": "a message"}})
    assert wrapty._stop_decision(nudge_state, [])[0] == wrapty.STOP_WAIT


def test_needing_the_user_beats_running_work():
    """A need_user() during a monitored session means the human's turn has
    come. Read it here or it leaks to a later, unrelated stop."""
    nudge_state = state(allow_stop=True, monitors={"inbox:1": {}})
    assert wrapty._stop_decision(nudge_state, [task()])[0] == wrapty.STOP_ALLOW
    assert nudge_state["allow_stop"] is False
    # The monitor still holds, so the stop after it is a wait, not a nudge.
    assert wrapty._stop_decision(nudge_state, [task()])[0] == wrapty.STOP_WAIT


def test_a_pending_resume_wins_and_clears_its_permission():
    nudge_state = state(allow_stop=True, resume="Continue.")
    assert wrapty._stop_decision(nudge_state, [task()]) == (
        wrapty.STOP_RESUME,
        "Continue.",
    )
    assert nudge_state["resume"] is None
    assert nudge_state["allow_stop"] is False


def test_a_pending_compaction_wins_over_everything():
    pending = {"instructions": "", "used_pct": 70}
    nudge_state = state(allow_stop=True, resume="Continue.", pending_compact=pending)
    assert wrapty._stop_decision(nudge_state, [task()]) == (
        wrapty.STOP_COMPACT,
        pending,
    )
    assert nudge_state["pending_compact"] is None
    assert nudge_state["resume"] is None
    assert nudge_state["allow_stop"] is False


def test_a_monitor_whose_listener_died_stops_counting():
    """monitor_done only runs when a listener exits cleanly. One killed with
    its terminal would otherwise silence the nudge for the whole session."""
    monitors = {
        "inbox:live": {"pid": 11, "timeout": None, "started": 0},
        "inbox:gone": {"pid": 12, "timeout": None, "started": 0},
    }
    dead = wrapty._dead_monitors(monitors, now=5, is_alive=lambda pid: pid == 11)
    assert dead == ["inbox:gone"]


def test_a_monitor_past_its_own_timeout_is_dead():
    monitors = {"inbox:slow": {"pid": None, "timeout": 30, "started": 100}}
    assert wrapty._dead_monitors(monitors, now=125, is_alive=lambda pid: True) == []
    assert wrapty._dead_monitors(monitors, now=131, is_alive=lambda pid: True) == [
        "inbox:slow"
    ]


def test_a_monitor_with_neither_a_pid_nor_a_timeout_is_left_alone():
    monitors = {"inbox:1": {"pid": None, "timeout": None, "started": 0}}
    assert wrapty._dead_monitors(monitors, now=10_000, is_alive=lambda pid: False) == []


def test_this_process_reads_as_alive():
    """The default liveness check, against the one pid we know is running."""
    assert wrapty._pid_alive(os.getpid()) is True
