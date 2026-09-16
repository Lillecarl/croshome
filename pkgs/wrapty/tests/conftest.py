"""A real wrapty, wrapping a real child, over a real pty.

Most of wrapty is testable as plain functions, and those tests are the ones
to add first. What this is for is the part that only exists as a running
wrapper: the control socket methods are closures inside _run, and their
effects are keystrokes on a terminal and files on disk.

The child is a shell that prints its WAPTY_ID and then echoes whatever it is
sent. Printing the id is how a test finds the control socket; echoing is how
a test sees what wrapty typed, since wrapty forwards the child's output to
its own stdout -- the pty the test holds the other end of.
"""

import os
import pty
import select
import subprocess
import sys
import time

import pytest

# Long enough for a loaded machine, short enough that a wedged wrapper fails
# the build instead of hanging it.
DEADLINE = 30.0


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


class Session:
    def __init__(self, process, master_fd):
        self.process = process
        self.master_fd = master_fd
        self.id = None

    def read_until(self, needle, deadline=None):
        """Everything the terminal has shown until `needle` appears. Returns
        (found, text)."""
        deadline = time.time() + DEADLINE if deadline is None else deadline
        text = ""
        while time.time() < deadline:
            ready, _, _ = select.select([self.master_fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(self.master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            text += chunk.decode(errors="replace")
            if needle in text:
                return True, text
        return needle in text, text


@pytest.fixture
def start_wrapty(tmp_path):
    """Start a wrapped session. Keyword arguments become environment
    variables, which is how the knobs in wrapper.py are set for a test."""
    sessions = []

    def start(**env_overrides):
        env = dict(os.environ)
        env["XDG_RUNTIME_DIR"] = _short_dir(tmp_path)
        env.update(env_overrides)

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

        session = Session(process, master_fd)
        sessions.append(session)

        found, text = session.read_until("READY:")
        assert found, f"wrapty never started its child; saw: {text!r}"
        session.id = text.split("READY:", 1)[1].split()[0].strip()
        return session

    yield start

    for session in sessions:
        session.process.kill()
        session.process.wait(timeout=10)
        os.close(session.master_fd)
