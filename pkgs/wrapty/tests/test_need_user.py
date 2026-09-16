"""need_user, against a running wrapper.

The point of the reason is that somebody reads it later and learns something
about when agents really stop. So the two things worth proving are that a
call with nothing to say is refused at the tool, and that a call that does
land writes down the state around it -- whether the agent had already been
nudged, and whether its own work was still running when it handed the turn
over. Those are the rows that answer the question.
"""

import asyncio
import json
import sys

import pytest

from wrapty.client import call

from fixtures import transcript_with_one_open_task, TASK_DESCRIPTION


def _records(state_home):
    path = state_home / "wrapty" / "journal.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()]


@pytest.mark.skipif(sys.platform == "win32", reason="needs a pty")
def test_a_reason_is_required(tmp_path, start_wrapty):
    session = start_wrapty(XDG_STATE_HOME=str(tmp_path / "state"))

    for empty in ("", "   ", "\n"):
        with pytest.raises(RuntimeError) as excinfo:
            asyncio.run(call(session.id, "need_user", {"reason": empty}))
        assert "reason" in str(excinfo.value)

    assert not (tmp_path / "state" / "wrapty" / "journal.jsonl").exists()


@pytest.mark.skipif(sys.platform == "win32", reason="needs a pty")
def test_the_call_records_the_state_around_it(tmp_path, start_wrapty):
    state_home = tmp_path / "state"
    transcript_path = str(tmp_path / "a-session-id.jsonl")
    transcript_with_one_open_task(transcript_path)

    session = start_wrapty(XDG_STATE_HOME=str(state_home))

    # A stop first, so the agent has been nudged once -- with no transcript
    # path yet, so there is nothing outstanding and the stop is a real nudge.
    result = asyncio.run(call(session.id, "on_stop"))
    assert result == {"nudge": True, "count": 1}

    # Now it learns about the transcript, and hands the turn back anyway
    # while that transcript still shows a task running.
    asyncio.run(call(session.id, "on_stop", {"transcript_path": transcript_path}))
    asyncio.run(
        call(session.id, "need_user", {"reason": "blocked on which host to deploy to"})
    )

    record = _records(state_home)[-1]
    assert record["event"] == "need_user"
    assert record["reason"] == "blocked on which host to deploy to"
    assert record["waiting"] == [TASK_DESCRIPTION]
    assert record["session_id"] == "a-session-id"
    assert record["transcript_path"] == transcript_path
    assert record["wapty_id"] == session.id


@pytest.mark.skipif(sys.platform == "win32", reason="needs a pty")
def test_a_stop_straight_after_a_nudge_is_marked(tmp_path, start_wrapty):
    """The pattern worth hunting: the agent was pushed back to work once and
    ended the turn again anyway."""
    state_home = tmp_path / "state"
    session = start_wrapty(XDG_STATE_HOME=str(state_home))

    asyncio.run(call(session.id, "need_user", {"reason": "the work is done"}))
    assert _records(state_home)[-1]["nudged"] is False

    # That call permitted one stop, so the stop it was made for is spent
    # first. The stop after it is the one that nudges.
    assert asyncio.run(call(session.id, "on_stop")) == {"nudge": False}
    assert asyncio.run(call(session.id, "on_stop")) == {"nudge": True, "count": 1}
    asyncio.run(call(session.id, "need_user", {"reason": "reporting what I found"}))

    record = _records(state_home)[-1]
    assert record["nudged"] is True
    assert record["stop_count"] == 1
