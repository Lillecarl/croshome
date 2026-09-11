import os
import subprocess
import sys
import time

import pytest

from ocahub.cli import Client


class Hub:
    def __init__(self, runtime, state):
        self.runtime = str(runtime)
        self.state = str(state)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "ocahub.daemon"],
            env=os.environ
            | {
                "OCAHUB_RUNTIME_DIR": self.runtime,
                "OCAHUB_STATE_DIR": self.state,
                "OCAHUB_LOG": "INFO",
            },
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                err = self.proc.stderr.read().decode(errors="replace")
                raise RuntimeError(f"daemon died at startup:\n{err}")
            try:
                self.client().ping()
                return
            except Exception as e:  # keep probing until the deadline
                last = e
                time.sleep(0.1)
        raise RuntimeError(f"daemon never answered ping: {last!r}")

    def client(self, **kw):
        if self.proc.poll() is not None:
            err = self.proc.stderr.read().decode(errors="replace")
            raise RuntimeError(f"daemon died during test:\n{err}")
        return Client(runtime=self.runtime, **kw)

    def subscribe(self, prefix=""):
        import zmq

        sub = zmq.Context().socket(zmq.SUB)
        sub.setsockopt(zmq.LINGER, 0)
        sub.setsockopt(zmq.SUBSCRIBE, prefix.encode())
        sub.setsockopt(zmq.RCVTIMEO, 10000)
        sub.connect(f"ipc://{self.runtime}/xpub.sock")
        return sub

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        # Handler tracebacks land here; show them on every teardown so a
        # failing test carries its daemon's side of the story.
        err = self.proc.stderr.read().decode(errors="replace")
        if err.strip():
            print(f"---- ocahubd stderr ----\n{err}", file=sys.stderr)


@pytest.fixture
def hub(tmp_path, monkeypatch):
    h = Hub(tmp_path / "runtime", tmp_path / "state")
    # The MCP tools and CLI resolve the hub from the environment, as in
    # production. The build sandbox is several times slower than a real
    # machine, so default timeouts must be overrideable.
    monkeypatch.setenv("OCAHUB_RUNTIME_DIR", h.runtime)
    monkeypatch.setenv("OCAHUB_STATE_DIR", h.state)
    monkeypatch.setenv("OCAHUB_TIMEOUT", "15")
    yield h
    h.stop()
