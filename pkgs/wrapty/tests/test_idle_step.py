"""The watchdog's pacing: when to ask a quiet session for a status.

The failure this guards against is a poke every interval forever. The
watchdog types into a real session, so a wait that is legitimate -- a long
build, a slow apply -- must cost a handful of pokes at most, and a session
whose work is actually moving must cost none.
"""

from wrapty import wrapper as wrapty

TASKS = [{"id": "b1", "kind": "command", "description": "a build", "deadline": 0}]
BASE = wrapty.IDLE_POKE_SEC


def step(progressed, moved, waiting, interval, pokes):
    return wrapty._idle_step(progressed, moved, waiting, interval, pokes)


def test_a_quiet_session_with_work_outstanding_is_poked():
    action, interval, pokes = step(False, False, TASKS, BASE, 0)
    assert action == wrapty.IDLE_POKE
    assert pokes == 1
    assert interval == min(BASE * 2, wrapty.IDLE_POKE_MAX_SEC)


def test_each_poke_waits_longer_than_the_last():
    interval, pokes = BASE, 0
    intervals = []
    for _ in range(3):
        action, interval, pokes = step(False, False, TASKS, interval, pokes)
        assert action == wrapty.IDLE_POKE
        intervals.append(interval)
    assert intervals == sorted(intervals)
    assert intervals[-1] <= wrapty.IDLE_POKE_MAX_SEC
    assert pokes == 3


def test_the_backoff_is_capped():
    _, interval, _ = step(False, False, TASKS, wrapty.IDLE_POKE_MAX_SEC, 1)
    assert interval == wrapty.IDLE_POKE_MAX_SEC


def test_an_answer_costs_no_poke_but_buys_no_reset():
    """The agent replying "still waiting" moves the transcript and changes
    nothing. It keeps the session off this tick's poke; it must not put the
    backoff back to the start, or a long build pays a turn every interval."""
    action, interval, pokes = step(False, True, TASKS, BASE * 4, 2)
    assert action == wrapty.IDLE_WAIT
    assert (interval, pokes) == (BASE * 4, 2)


def test_work_that_actually_changed_resets_the_backoff():
    """A task reporting, or a new one starting, is the session getting
    somewhere. Start the patience over."""
    action, interval, pokes = step(True, True, TASKS, BASE * 4, 2)
    assert action == wrapty.IDLE_WAIT
    assert (interval, pokes) == (BASE, 0)


def test_the_watch_ends_when_the_work_is_done():
    for progressed in (True, False):
        for moved in (True, False):
            assert step(progressed, moved, [], BASE, 1)[0] == wrapty.IDLE_STOP


def test_a_long_wait_costs_a_handful_of_pokes_and_then_stops():
    """The shape of a 40-minute apply that the agent answers every time: the
    poke count still climbs to the limit, so the watch ends."""
    interval, pokes, poked = BASE, 0, 0
    while pokes < wrapty.IDLE_POKE_LIMIT:
        action, interval, pokes = step(False, False, TASKS, interval, pokes)
        if action == wrapty.IDLE_POKE:
            poked += 1
            # the agent answers, which moves the transcript and nothing else
            action, interval, pokes = step(False, True, TASKS, interval, pokes)
            assert action == wrapty.IDLE_WAIT
    assert poked == wrapty.IDLE_POKE_LIMIT
