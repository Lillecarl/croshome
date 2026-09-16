"""The idle watchdog, end to end: a real wrapty, a real pty, a real poke.

Everything else about the watchdog is unit tested -- _idle_step decides the
pacing, wrapty.transcript decides what counts as outstanding work. What no
unit test can reach is the loop that joins them, because it is a closure
inside _run and its side effect is keystrokes on a terminal.

So this runs the wrapper for real. The child is a shell that prints its
WAPTY_ID and then echoes whatever it is sent, which is what makes a poke
visible: wrapty types into the child's pty, the child echoes, and wrapty
forwards that to its own stdout -- the pty this test holds the other end of.

The knobs come from the environment (see IDLE_POKE_SEC in wrapper.py), so a
watch that takes five minutes in a session takes a second here.
"""

import asyncio
import json
import os
import pty
import select
import subprocess
import sys
import time

import pytest

from wrapty.client import call

# Long enough for a machine under load, short enough that a broken watchdog
# fails the build rather than hanging it. The poke itself is due after 1s.
POKE_DEADLINE = 30.0

POKE_TEXT = "WATCHDOG-FIRED for {tasks}"
TASK_DESCRIPTION = "wait for the flag"


def _short_dir(tmp_path):
    """The shortest writable directory available, for the control socket.

    AF_UNIX paths cannot exceed 104 bytes on darwin, and a build sandbox puts
    pytest's tmp_path well past that -- the same reason test_control_socket.py
    picks its own directory.
    """
    best = str(tmp_path)
    for candidate in (os.getcwd(), os.environ.get("TMPDIR", ""), "/tmp"):
        if candidate and os.path.isdir(candidate) and os.access(candidate, os.W_OK):
            if len(candidate) < len(best):
                best = candidate
    return best


def _transcript_with_one_open_task(path):
    """A transcript holding a background command that never reported."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    entries = [
        {
            "type": "assistant",
            "timestamp": stamp,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Bash",
                        "input": {
                            "command": "until [ -f flag ]; do sleep 5; done",
                            "description": TASK_DESCRIPTION,
                            "run_in_background": True,
                        },
                    }
                ],
            },
        },
        {
            "type": "user",
            "timestamp": stamp,
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"}
                ],
            },
            "toolUseResult": {"backgroundTaskId": "bwatch1"},
        },
    ]
    with open(path, "w") as handle:
        for entry in entries:
            handle.write(json.dumps(entry) + "\n")


def _read_until(master_fd, needle, deadline):
    """Everything read from the pty until `needle` shows up, or until the
    deadline. Returns (found, text)."""
    text = ""
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 0.2)
        if not ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        text += chunk.decode(errors="replace")
        if needle in text:
            return True, text
    return needle in text, text


@pytest.mark.skipif(sys.platform == "win32", reason="needs a pty")
def test_a_quiet_session_with_work_outstanding_is_poked(tmp_path):
    runtime_dir = _short_dir(tmp_path)
    transcript_path = str(tmp_path / "transcript.jsonl")
    _transcript_with_one_open_task(transcript_path)

    env = dict(os.environ)
    env.update(
        XDG_RUNTIME_DIR=runtime_dir,
        WRAPTY_IDLE_POKE_SEC="1",
        WRAPTY_IDLE_POKE_LIMIT="1",
        WRAPTY_IDLE_POKE_TEXT=POKE_TEXT,
        # The typing delays exist to look human to the wrapped TUI. Nothing
        # here is watching for that, and they are pure latency in a test.
        WRAPTY_TYPE_CHUNK_DELAY="0",
        WRAPTY_ENTER_DELAY_JITTER="0",
    )

    master_fd, slave_fd = pty.openpty()
    process = subprocess.Popen(
        [sys.executable, "-m", "wrapty.wrapper", "sh", "-c",
         "echo READY:$WAPTY_ID; cat"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        close_fds=True,
    )
    os.close(slave_fd)

    try:
        deadline = time.time() + POKE_DEADLINE
        found, text = _read_until(master_fd, "READY:", deadline)
        assert found, f"wrapty never started its child; saw: {text!r}"
        wapty_id = text.split("READY:", 1)[1].split()[0].strip()

        # The stop that arms the watch: work outstanding, nothing else
        # permitting the stop.
        result = asyncio.run(
            call(wapty_id, "on_stop", {"transcript_path": transcript_path})
        )
        assert result["nudge"] is False
        assert TASK_DESCRIPTION in result["waiting_on"]

        # Nothing touches the transcript from here, so the session is quiet
        # and the watchdog is due to poke after its one second.
        #
        # Waiting on the description rather than the marker waits for the
        # whole line: the marker opens the poke and arrives a chunk earlier,
        # so stopping there would read only half of what was typed.
        found, text = _read_until(master_fd, TASK_DESCRIPTION, deadline)
        assert found, f"the watchdog never poked; pty held: {text!r}"
        assert "WATCHDOG-FIRED" in text, "the poke arrived without its text"
    finally:
        process.kill()
        process.wait(timeout=10)
        os.close(master_fd)
