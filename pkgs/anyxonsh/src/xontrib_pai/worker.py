"""One event loop, on one thread, outliving every prompt.

The shell has nowhere to run a coroutine. xonsh's prompt is drawn by
prompt_toolkit calling `asyncio.run`, which builds a loop, runs the prompt, and
closes the loop again when you press Enter -- so anything started during a
prompt is cancelled by submitting the line that started it. Between prompts
there is no loop at all: measured in a live shell, `asyncio.get_running_loop()`
raises while a command is running.

A loop we own instead has neither problem, but only if something drives it. A
loop that merely exists does not advance -- driven by the prompt it would freeze
for exactly as long as each command takes, which is the wrong half of the day to
be frozen. So it gets a thread, and the thread does nothing else.

What that buys is the whole point of the exercise: `ask` returns immediately,
the prompt comes back, and the answer arrives whenever it arrives. What it costs
is that the agent now runs somewhere the shell's own machinery does not expect
-- `run_xonsh` in particular has to come back to the main thread before it can
touch the session, which is `tools`' problem rather than this module's.

One request at a time, and that is a correctness rule rather than politeness:
the conversation is a list that each request appends its turns to, so two in
flight would interleave into a history that never happened.
"""

from __future__ import annotations

import asyncio
import threading

#: How long `shutdown` waits for the loop to stop before giving up on it. The
#: thread is a daemon, so the process is not held up either way; this is only
#: about giving a request in flight a chance to notice it was cancelled.
SHUTDOWN_GRACE = 2.0


class Busy(Exception):
    """Raised by `submit` when a request is already in flight."""


class Worker:
    """A thread running an event loop, and at most one request on it."""

    def __init__(self) -> None:
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._task: asyncio.Task | None = None
        # Guards the three above against `submit` and `cancel` racing, which
        # they will: one is called from the shell and the other from a
        # keybinding, and both are the main thread only by coincidence.
        self._lock = threading.RLock()

    # --- The loop ----------------------------------------------------------

    def _start(self) -> asyncio.AbstractEventLoop:
        """The loop, started if it is not running yet.

        Started on first use rather than at load: a shell that never asks the
        model anything should not be paying for a thread, and `xontrib load pai`
        happens in every shell.
        """
        if self._loop is not None:
            return self._loop

        loop = asyncio.new_event_loop()
        ready = threading.Event()

        def run() -> None:
            asyncio.set_event_loop(loop)
            loop.call_soon(ready.set)
            loop.run_forever()
            # Draining here rather than in `shutdown`: async generators have to
            # be closed by the loop that owns them, and by the time `shutdown`
            # returns this thread is the only one that can still do it.
            try:
                loop.run_until_complete(loop.shutdown_asyncgens())
            finally:
                loop.close()

        # Daemon, so a shell that exits mid-request exits rather than waiting
        # for a model to finish answering a question nobody is there to read.
        self._thread = threading.Thread(target=run, name="pai-worker", daemon=True)
        self._thread.start()
        ready.wait(timeout=SHUTDOWN_GRACE)
        self._loop = loop
        return loop

    @property
    def running(self) -> bool:
        """Is there a loop to run things on?"""
        return self._loop is not None

    # --- Requests ----------------------------------------------------------

    @property
    def busy(self) -> bool:
        """Is a request in flight?"""
        with self._lock:
            return self._task is not None and not self._task.done()

    def submit(self, work, done=None):
        """Start `work()` on the loop and return at once.

        Args:
            work: an async callable taking no arguments. Called on the worker
                thread, so what it touches is its own business to get right.
            done: called with `(result, exception)` when it finishes, with both
                `None` if it was cancelled. Called on the worker thread.

        Raises:
            Busy: a request is already in flight. Refused rather than queued --
                a queue would let someone type four questions and then wait for
                all four, and the fourth was probably about the first's answer.
        """
        with self._lock:
            if self.busy:
                raise Busy("a request is already in flight")
            loop = self._start()

            async def run():
                try:
                    result = await work()
                except asyncio.CancelledError:
                    if done is not None:
                        done(None, None)
                    raise
                except BaseException as exc:  # noqa: BLE001 - handed to `done`
                    if done is not None:
                        done(None, exc)
                    return None
                if done is not None:
                    done(result, None)
                return result

            # Created on the loop thread: `ensure_future` binds the task to
            # whichever loop is current, and the current loop *here* is either
            # none at all or prompt_toolkit's, neither of which is ours.
            made = threading.Event()

            def make() -> None:
                with self._lock:
                    self._task = asyncio.ensure_future(run())
                made.set()

            loop.call_soon_threadsafe(make)

        made.wait(timeout=SHUTDOWN_GRACE)
        return self._task

    def cancel(self) -> bool:
        """Stop the request in flight. `False` if there was not one."""
        with self._lock:
            task, loop = self._task, self._loop
            if task is None or loop is None or task.done():
                return False
        loop.call_soon_threadsafe(task.cancel)
        return True

    def shutdown(self) -> None:
        """Stop the loop and forget it. Safe to call twice, or never having run."""
        with self._lock:
            loop, thread, task = self._loop, self._thread, self._task
            self._loop = self._thread = self._task = None
        if loop is None:
            return

        def stop() -> None:
            # Cancelled before stopping, and stopped only once the cancellation
            # has been delivered. Stopping a loop out from under a live task
            # leaves asyncio to complain about it on stderr at exit -- which,
            # for a shell exited mid-request, means a traceback-shaped thing
            # arriving after the user has already typed their next command.
            if task is not None and not task.done():
                task.cancel()
                loop.call_soon(loop.stop)
            else:
                loop.stop()

        loop.call_soon_threadsafe(stop)
        if thread is not None:
            thread.join(timeout=SHUTDOWN_GRACE)
