"""
The TUI harness: opencode in pymux in foot on a headless compositor.

Every layer is the real program. sway runs headless (no card, no
input devices -- a build sandbox has neither), foot paints the
compositor's whole output, pymux holds the pane opencode runs in, and
the check drives and reads through pymux's control socket the way
libtmux drives tmux:

    await tui.send_keys("hello", enter=True)   # type at the TUI
    await tui.capture()                        # the pane, as text
    await tui.screenshot(path)                 # the window, as a picture
    await tui.wait(lambda t: "sent" in t)      # fence on the capture channel

The harness is async because its checks are: several agents run at
once on the test's event loop, each a task -- the shape ocahub itself
is for. What only the pixels show lives in the screenshots; everything
else asserts on the capture, which is bytes and not pixels. The sync
problem is met on the capture channel: a screen that is waiting for
input is still, so two identical captures in a row mean the frame is
whole, and typing into it is not a race.
"""

import asyncio
import os
import shlex
import sys
import time
from pathlib import Path

#: Long enough for a cold opencode on a slow, loaded sandbox, and for
#: the MCP round trips in between.
DEFAULT_TIMEOUT = 180.0


def _heartbeat(what, started, last_beat):
    """
    One line every fifteen seconds while a wait runs.

    The checks are quiet for minutes at a time on a loaded sandbox --
    pytest prints nothing between them -- and a quiet run is exactly
    what a stalled one looks like from the outside. The heartbeat is
    what makes the difference visible in a build log: real progress
    grows the log, and a stall stays silent through it.

    Returns the beat to compare the next call against.
    """
    elapsed = time.monotonic() - started
    if elapsed - last_beat >= 15:
        print("[%s] %ds" % (what, int(elapsed)), flush=True)
        return elapsed
    return last_beat


class TuiError(RuntimeError):
    pass


def _tail(path, lines=40):
    try:
        return "\n".join(Path(path).read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no log)"


class Tui:
    """
    One opencode TUI, in a pane of its own, and the ways to read it.

    `opencode_env` is the environment the TUI runs under: the XDG
    roots, the mock provider's config, the hub's directories, and the
    hub name this instance's MCP server registers under. Whatever it
    names must already exist on disk.
    """

    def __init__(self, work, project, opencode_env, rows=30, columns=100):
        self.work = Path(work)
        self.project = Path(project)
        self.opencode_env = dict(opencode_env)
        self.rows = rows
        self.columns = columns

        self.sock = self.work / "pymux.sock"
        self.server_log = self.work / "pymux-server.log"
        self.sway_log = self.work / "sway.log"
        self.room = self.work / "seat"
        self.room.mkdir(parents=True, exist_ok=True)
        self._display = None
        self._sway = None

    # -- the control socket --------------------------------------------

    async def _cli(self, args, timeout=30):
        process = await asyncio.create_subprocess_exec(
            "pymux",
            "-S",
            str(self.sock),
            *[str(a) for a in args],
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
        if process.returncode != 0:
            raise TuiError(
                "pymux %s failed (%d):\n%s"
                % (
                    " ".join(map(str, args)),
                    process.returncode,
                    stderr.decode(errors="replace"),
                )
            )
        return stdout.decode(errors="replace")

    # -- start and stop -------------------------------------------------

    async def start(self, timeout=DEFAULT_TIMEOUT):
        """
        Start the server with opencode in the pane, then the seat that
        shows it, and wait until the TUI has drawn and gone still.
        """
        env = {
            **os.environ,
            **self.opencode_env,
            "SHELL": os.environ.get("OCABUILD_SHELL", "/bin/sh"),
            "LANG": "C.UTF-8",
        }
        started = await asyncio.create_subprocess_exec(
            "pymux",
            "--log",
            str(self.server_log),
            "-S",
            str(self.sock),
            "new-session",
            "-d",
            "-s",
            "test",
            "opencode",
            cwd=str(self.project),
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _stdout, stderr = await asyncio.wait_for(started.communicate(), timeout)
        if started.returncode != 0:
            raise TuiError(
                "the pymux server never started:\n%s" % stderr.decode(errors="replace")
            )
        await self._start_sway()
        await self.wait(lambda t: t.strip() != "")
        await self.wait_settled()

    async def _start_sway(self):
        wrapper = self.room / "run.sh"
        wrapper.write_text(
            "cd %s\nexec foot -e pymux -S %s attach\n"
            % (shlex.quote(str(self.project)), shlex.quote(str(self.sock)))
        )
        config = self.room / "sway.conf"
        config.write_text(
            "default_border none\n"
            "output HEADLESS-1 resolution 1024x768\n"
            "exec /bin/sh %s\n" % shlex.quote(str(wrapper))
        )
        self._sway = await asyncio.create_subprocess_exec(
            "sway",
            "-c",
            str(config),
            stdout=open(self.sway_log, "wb"),
            stderr=asyncio.subprocess.STDOUT,
            env={
                **os.environ,
                "XDG_RUNTIME_DIR": str(self.room),
                "WLR_BACKENDS": "headless",
                "WLR_RENDERER": "pixman",
                "WLR_LIBINPUT_NO_DEVICES": "1",
                "LIBSEAT_BACKEND": "noop",
                "DISPLAY": "",
            },
        )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self._sway.returncode is not None:
                raise TuiError(
                    "sway died at startup (%s):\n%s"
                    % (self._sway.returncode, _tail(self.sway_log))
                )
            sockets = [
                s for s in self.room.glob("wayland-*") if not s.name.endswith(".lock")
            ]
            if sockets:
                self._display = sockets[0].name
                return
            await asyncio.sleep(0.2)
        raise TuiError("sway never opened a display:\n%s" % _tail(self.sway_log))

    async def stop(self):
        if self.sock.exists():
            try:
                await self._cli(["kill-server"])
            except (TuiError, asyncio.TimeoutError, FileNotFoundError):
                pass
        if self._sway is not None and self._sway.returncode is None:
            self._sway.terminate()
            try:
                await asyncio.wait_for(self._sway.wait(), 5)
            except asyncio.TimeoutError:
                self._sway.kill()

    # -- the ways to read, and one to write ------------------------------

    async def send_keys(self, text, enter=False):
        "Type at the TUI, literally, and optionally press Enter after it."
        if text:
            await self._cli(["send-keys", "-l", text])
        if enter:
            await self._cli(["send-keys", "Enter"])

    async def capture(self):
        "The pane as text, wrapped lines joined."
        return await self._cli(["capture-pane", "-p", "-J"])

    async def screenshot(self, path):
        "The whole output, as a picture. This is the AI-viewable one."
        process = await asyncio.create_subprocess_exec(
            "grim",
            str(path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={
                **os.environ,
                "XDG_RUNTIME_DIR": str(self.room),
                "WAYLAND_DISPLAY": self._display,
            },
        )
        _stdout, stderr = await asyncio.wait_for(process.communicate(), 30)
        if process.returncode != 0:
            raise TuiError("grim failed:\n%s" % stderr.decode(errors="replace"))
        return Path(path)

    # -- the fences ------------------------------------------------------

    async def wait_settled(self, timeout=DEFAULT_TIMEOUT):
        """
        Wait until two captures in a row agree, and give back the text.

        A TUI that animates (a spinner, a clock) never settles; a field
        that waits for input does. The wait bounds itself, so an
        animated screen costs the timeout and then says what moved.
        """
        deadline = time.monotonic() + timeout
        previous = None
        beat = 0.0
        began = time.monotonic()
        while time.monotonic() < deadline:
            current = await self.capture()
            if current and current == previous:
                return current
            previous = current
            beat = _heartbeat("settle", began, beat)
            await asyncio.sleep(0.5)
        raise TuiError("the pane never settled; the last two captures differ")

    async def wait(self, predicate, timeout=DEFAULT_TIMEOUT):
        """
        Wait until the capture answers to `predicate`, and give back
        the capture that did.

        The screen of a program that is thinking changes often, so
        this polls the capture and not the clock. The failure carries
        the last capture and the server log, which is the difference
        between "the check failed" and "here is why".
        """
        deadline = time.monotonic() + timeout
        last = ""
        beat = 0.0
        began = time.monotonic()
        while time.monotonic() < deadline:
            last = await self.capture()
            if predicate(last):
                return last
            beat = _heartbeat("wait", began, beat)
            await asyncio.sleep(0.5)
        raise TuiError(
            "the pane never showed it; the last capture was:\n%s\n%s"
            % (last, _tail(self.server_log))
        )
