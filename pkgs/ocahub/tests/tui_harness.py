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
is for. The primitives are anyio's throughout: subprocesses come from
`anyio.open_process`, waits from timeout scopes, so a stuck child is
cancelled (and killed) instead of wedging the run. What only the
pixels show lives in the screenshots; everything else asserts on the
capture, which is bytes and not pixels. The sync problem is met on
the capture channel: a screen that is waiting for input is still, so
two identical captures in a row mean the frame is whole, and typing
into it is not a race.
"""

import os
import shlex
import subprocess
import time
from pathlib import Path

import anyio

#: How long a fence may run. The things fenced on -- a hub delivery, a
#: pane reply, a still frame -- are work of seconds; the budget covers
#: a cold opencode on a loaded sandbox, and a failure is what the
#: fence is for. The per-test backstop is pytest-timeout's, and it
#: sits above this.
DEFAULT_TIMEOUT = 30.0


class TuiError(RuntimeError):
    pass


def _tail(path, lines=40):
    try:
        return "\n".join(Path(path).read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no log)"


async def _communicate(process):
    """
    Both pipes drained to EOF, as (stdout, stderr) bytes.

    anyio's process has no `communicate`; a task group drains the two
    streams at once, and the caller's timeout scope bounds the whole
    thing -- a child that will not end is cancelled, and the caller
    kills it in the TimeoutError it then sees.
    """

    async def drain(stream, chunks):
        while True:
            try:
                chunk = await stream.receive(max_bytes=65536)
            except anyio.EndOfStream:
                # The child closed its side: that is the EOF the
                # communicator waits for, not a fault.
                return
            chunks.append(chunk)

    out, err = [], []
    async with anyio.create_task_group() as tg:
        tg.start_soon(drain, process.stdout, out)
        tg.start_soon(drain, process.stderr, err)
    return b"".join(out), b"".join(err)


def _proc_dump():
    """
    The pane process's kernel view, for a TUI that never paints.

    A pane that stays blank with its process alive is either a boot
    that has not finished or a syscall it never comes back from; the
    wait channel and the state line say which. Off by default -- the
    check turns it on with OCAHUB_DEBUG_PROC when it wants the truth.
    """
    lines = []
    for pid in Path("/proc").iterdir():
        if not pid.name.isdigit():
            continue
        try:
            cmd = (pid / "cmdline").read_bytes().decode(errors="replace")
        except OSError:
            continue
        if (
            "opencode" not in cmd
            and "foot" not in cmd
            and "pymux" not in cmd
            and "ocahub" not in cmd
        ):
            continue
        fields = {}
        try:
            for field in (pid / "status").read_text().splitlines():
                if field.startswith(("State:", "Threads:")):
                    fields[field.split(":")[0]] = field.split(":", 1)[1].strip()
        except OSError:
            continue
        try:
            wchan = (pid / "wchan").read_text(errors="replace").strip()
        except OSError:
            wchan = "?"
        lines.append(
            "proc %s %s wchan=%s %s :: %s"
            % (pid.name, fields.get("State", "?"), wchan, fields.get("Threads", "?"), cmd[:100])
        )
    return "\n\nthe pane's processes:\n" + "\n".join(lines)


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


class Tui:
    """
    One agent TUI, in a pane of its own, and the ways to read it.

    `agent_env` is the environment the agent runs under: the XDG
    roots, the mock provider's config, the hub's directories, and the
    hub name this instance's MCP server registers under. Whatever it
    names must already exist on disk. `command` is the binary the
    pane runs -- opencode, claude -- started in `project`.
    """

    def __init__(self, work, project, agent_env, rows=30, columns=100, command="opencode"):
        self.work = Path(work)
        self.project = Path(project)
        self.agent_env = dict(agent_env)
        self.command = command
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
        process = await anyio.open_process(
            ["pymux", "-S", str(self.sock)] + [str(a) for a in args],
        )
        try:
            with anyio.fail_after(timeout):
                stdout, stderr = await _communicate(process)
                await process.wait()
        except TimeoutError:
            process.kill()
            raise TuiError("pymux %s did not end in time" % " ".join(map(str, args)))
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

    async def start(self, timeout=120.0):
        """
        Start the server with the agent in the pane, then the seat that
        shows it, and wait until the TUI has drawn and gone still.

        The budget is the boot's, not the conversation's: with the hub
        plugin deployed, opencode spends its first ~70s trying to
        install the plugin's npm dependency against the sandbox's dead
        network before its first frame (measured, in the run's own
        opencode.log). What the agent does once drawn is fenced at
        DEFAULT_TIMEOUT.
        """
        env = {
            **os.environ,
            **self.agent_env,
            "SHELL": os.environ.get("OCABUILD_SHELL", "/bin/sh"),
            "LANG": "C.UTF-8",
        }
        process = await anyio.open_process(
            [
                "pymux",
                "--log",
                str(self.server_log),
                "-S",
                str(self.sock),
                "new-session",
                "-d",
                "-s",
                "test",
                self.command,
            ],
            cwd=str(self.project),
            env=env,
        )
        try:
            with anyio.fail_after(timeout):
                _stdout, stderr = await _communicate(process)
                await process.wait()
        except TimeoutError:
            process.kill()
            raise TuiError("the pymux server did not start in time")
        if process.returncode != 0:
            raise TuiError(
                "the pymux server never started:\n%s" % stderr.decode(errors="replace")
            )
        await self._start_sway()
        await self.wait(lambda t: t.strip() != "", timeout=timeout)
        await self.wait_settled(timeout=timeout)

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
        with open(self.sway_log, "wb") as log:
            self._sway = await anyio.open_process(
                ["sway", "-c", str(config)],
                stdout=log,
                stderr=subprocess.STDOUT,
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
        # A display socket appears in under a second or sway is dead;
        # twenty is already charity for a sandbox under load.
        try:
            with anyio.fail_after(20):
                beat = 0.0
                began = time.monotonic()
                while True:
                    if self._sway.returncode is not None:
                        raise TuiError(
                            "sway died at startup (%s):\n%s"
                            % (self._sway.returncode, _tail(self.sway_log))
                        )
                    sockets = [
                        s
                        for s in self.room.glob("wayland-*")
                        if not s.name.endswith(".lock")
                    ]
                    if sockets:
                        self._display = sockets[0].name
                        return
                    beat = _heartbeat("sway", began, beat)
                    await anyio.sleep(0.2)
        except TimeoutError:
            raise TuiError("sway never opened a display:\n%s" % _tail(self.sway_log))

    async def stop(self):
        if self.sock.exists():
            try:
                await self._cli(["kill-server"])
            except (TuiError, TimeoutError, FileNotFoundError):
                pass
        if self._sway is not None and self._sway.returncode is None:
            self._sway.terminate()
            with anyio.move_on_after(5):
                await self._sway.wait()
            if self._sway.returncode is None:
                self._sway.kill()

    # -- the ways to read, and one to write ------------------------------

    async def send_keys(self, text, enter=False):
        "Type at the TUI, literally, and optionally press Enter after it."
        if text:
            await self._cli(["send-keys", "-l", text])
        if enter:
            await self._cli(["send-keys", "Enter"])

    async def key(self, name):
        """
        Press one named key -- `Tab`, `Enter`, `C-u` -- by pymux's key
        spelling, and not as text.
        """
        await self._cli(["send-keys", name])

    async def hello(self, reply="hello"):
        """
        Open the session: send one prompt and fence on the mock's reply.

        opencode opens no session at all until the first prompt goes to
        the AI -- nothing to rename, nothing registered on the hub --
        so every check starts here, and every script's first turn is
        the answer this waits for.
        """
        await self.send_keys("hello", enter=True)
        await self.wait(lambda t: reply in t.lower())

    async def rename(self, title):
        """
        Rename the session, by the /rename command: it takes no
        arguments -- submitting it opens the rename prompt, prefilled
        with the current title, so C-u clears the line before the new
        title goes in.

        The fence between the command and the typing is the dialog
        itself, identified by its own screen text ("Rename Session"):
        a command that opened nothing fails there with the pane in
        the message, instead of typing the title into the void.
        """
        await self.send_keys("/rename", enter=True)
        await self.wait(lambda t: "rename session" in t.lower(), timeout=10)
        await self.key("C-u")
        await self.send_keys(title, enter=True)

    async def capture(self):
        """
        The pane as text, wrapped lines joined. The last good capture
        is kept: a pane whose process has exited takes the pymux
        server with it, and the next capture fails -- the screen the
        agent died on is then only available from here.
        """
        try:
            self._last_capture = await self._cli(["capture-pane", "-p", "-J"])
        except TuiError:
            if getattr(self, "_last_capture", None):
                raise TuiError(
                    "the pane is gone (the pymux server with it); the last "
                    "capture before death was:\n" + self._last_capture
                )
            raise
        return self._last_capture

    async def screenshot(self, path):
        "The whole output, as a picture. This is the AI-viewable one."
        process = await anyio.open_process(
            ["grim", str(path)],
            env={
                **os.environ,
                "XDG_RUNTIME_DIR": str(self.room),
                "WAYLAND_DISPLAY": self._display,
            },
        )
        try:
            with anyio.fail_after(30):
                _stdout, stderr = await _communicate(process)
                await process.wait()
        except TimeoutError:
            process.kill()
            raise TuiError("grim did not end in time")
        if process.returncode != 0:
            raise TuiError("grim failed:\n%s" % stderr.decode(errors="replace"))
        return Path(path)

    # -- the fences ------------------------------------------------------

    async def wait_settled(self, timeout=DEFAULT_TIMEOUT):
        """
        Wait until two captures in a row agree, and give back the text.

        A TUI that animates (a spinner, a clock) never settles; a field
        that waits for input does. The whole loop sits inside one
        timeout scope, so a hung capture is caught with the polling,
        not only between polls; an animated screen costs the timeout
        and then says what moved.
        """
        previous = None
        beat = 0.0
        began = time.monotonic()
        try:
            with anyio.fail_after(timeout):
                while True:
                    current = await self.capture()
                    if current and current == previous:
                        return current
                    previous = current
                    beat = _heartbeat("settle", began, beat)
                    await anyio.sleep(0.5)
        except TimeoutError:
            raise TuiError(
                "the pane never settled in %ds; the last capture was:\n%s"
                % (int(timeout), (previous or "")[-2000:])
            )

    async def wait(self, predicate, timeout=DEFAULT_TIMEOUT):
        """
        Wait until the capture answers to `predicate`, and give back
        the capture that did.

        The screen of a program that is thinking changes often, so
        this polls the capture and not the clock. The whole loop sits
        inside one timeout scope -- a hung capture dies with the
        polling, not after it. The failure carries the last capture
        and the server log, which is the difference between "the
        check failed" and "here is why".
        """
        last = ""
        beat = 0.0
        began = time.monotonic()
        try:
            with anyio.fail_after(timeout):
                while True:
                    last = await self.capture()
                    if predicate(last):
                        return last
                    beat = _heartbeat("wait", began, beat)
                    await anyio.sleep(0.5)
        except TimeoutError:
            raise TuiError(
                "the pane never showed it in %ds; the last capture was:\n%s\n%s%s"
                % (
                    int(timeout),
                    last,
                    _tail(self.server_log),
                    _proc_dump() if os.environ.get("OCAHUB_DEBUG_PROC") else "",
                )
            )
