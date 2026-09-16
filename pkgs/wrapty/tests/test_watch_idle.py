"""The idle watchdog, end to end: a real wrapty, a real pty, a real poke.

Everything else about the watchdog is unit tested -- _idle_step decides the
pacing, wrapty.transcript decides what counts as outstanding work. What no
unit test can reach is the loop that joins them, because it is a closure
inside _run and its side effect is keystrokes on a terminal.

The knobs come from the environment (see IDLE_POKE_SEC in wrapper.py), so a
watch that takes five minutes in a session takes a second here.
"""

import asyncio
import sys

import pytest

from wrapty.client import call

from fixtures import transcript_with_one_open_task, TASK_DESCRIPTION

POKE_TEXT = "WATCHDOG-FIRED for {tasks}"


@pytest.mark.skipif(sys.platform == "win32", reason="needs a pty")
def test_a_quiet_session_with_work_outstanding_is_poked(tmp_path, start_wrapty):
    transcript_path = str(tmp_path / "transcript.jsonl")
    transcript_with_one_open_task(transcript_path)

    session = start_wrapty(
        WRAPTY_IDLE_POKE_SEC="1",
        WRAPTY_IDLE_POKE_LIMIT="1",
        WRAPTY_IDLE_POKE_TEXT=POKE_TEXT,
        # The typing delays exist to look human to the wrapped TUI. Nothing
        # here watches for that, and they are pure latency in a test.
        WRAPTY_TYPE_CHUNK_DELAY="0",
        WRAPTY_ENTER_DELAY_JITTER="0",
    )

    # The stop that arms the watch: work outstanding, nothing else permitting
    # the stop.
    result = asyncio.run(
        call(session.id, "on_stop", {"transcript_path": transcript_path})
    )
    assert result["nudge"] is False
    assert TASK_DESCRIPTION in result["waiting_on"]

    # Nothing touches the transcript from here, so the session is quiet and
    # the watchdog is due to poke after its one second.
    #
    # Waiting on the description rather than the marker waits for the whole
    # line: the marker opens the poke and arrives a chunk earlier, so
    # stopping there would read only half of what was typed.
    found, text = session.read_until(TASK_DESCRIPTION)
    assert found, f"the watchdog never poked; pty held: {text!r}"
    assert "WATCHDOG-FIRED" in text, "the poke arrived without its text"
