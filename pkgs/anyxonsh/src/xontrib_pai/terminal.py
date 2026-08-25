"""Writing to the terminal from a thread that does not own it.

Once the agent runs on a worker thread, everything it wants to say arrives at a
moment nobody chose: you may be at a prompt halfway through typing a command,
or you may be watching a build scroll past. Those are different terminals to
write to, and the difference is not cosmetic -- a bare `print` into a live
prompt writes over the line you are typing and leaves prompt_toolkit's idea of
the screen disagreeing with the screen.

So there are two paths and one rule for choosing between them:

* A prompt is on screen -- hand the write to prompt_toolkit, which hides the
  prompt, writes, and draws it again underneath. The typed line survives.
* No prompt -- a command is running, or the shell is starting up. Nothing owns
  the terminal, so write straight to it like anything else.

Everything goes to stderr either way, so a `: ...` line piped somewhere still
yields only the answer.

The check and the write cannot be made one atomic thing: the prompt can end
between deciding it is there and writing to it. That race is unavoidable and
survivable, so every path here degrades to a plain write rather than raising --
a progress line lost to a torn-down prompt is a cosmetic problem, and an
exception on a worker thread mid-request is not.
"""

from __future__ import annotations

#: How long `interact` waits for the prompt's loop to *start* the work before
#: doing it here instead. Long enough that a busy shell is not given up on,
#: short enough that a request never simply stops -- for an approval, waiting
#: for ever means waiting on a question the user was never shown.
#:
#: To start it, and emphatically not to finish it. This was once the whole
#: wait, from before the work runs to after it returns, and that was a bug with
#: teeth: the work is now a command running to completion, so anything taking
#: longer than this timed out and was *run a second time* on this thread. Ten
#: seconds is a perfectly ordinary length for a command, and the second copy
#: ran somewhere no signal handler can be installed, which is how a Ctrl+C to
#: it did nothing and then took the shell down. See `interact`.
HANDOVER_TIMEOUT = 10.0

#: How long `interact` waits for a prompt to turn up before deciding there is
#: not going to be one. See `pending`; a second is far longer than the gap
#: between one prompt ending and the next beginning, and it is only ever spent
#: when a command really is running.
PROMPT_GRACE = 1.0

#: How often that wait looks. Short enough that the usual case -- the prompt is
#: already there, or arrives within a frame or two -- costs nothing worth
#: measuring.
PROMPT_POLL = 0.02


def session():
    """xonsh's `PromptSession`, or `None` when there is not one.

    Reached for through the shell rather than through prompt_toolkit's
    `get_app`, which is thread-local: from the worker thread it always answers
    `None`, whatever is on screen. This is the same object no matter which
    thread asks.
    """
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return None
    return getattr(getattr(XSH, "shell", None), "shell", None)


def prompt():
    """The prompt_toolkit application currently drawing a prompt, or `None`.

    `None` covers every way there might be nothing to draw underneath: no
    xonsh, a non-prompt_toolkit shell, a prompt that has not started yet, and
    the common one -- a command is running, so the prompt is over.
    """
    app = getattr(getattr(session(), "prompter", None), "app", None)
    if app is None or app.loop is None or not app.is_running:
        return None
    return app


def pending(grace: float = PROMPT_GRACE):
    """The prompt, waiting up to `grace` seconds for one to appear.

    `prompt()` answers about this instant, which is the wrong question when the
    answer decides who owns the terminal for the next several seconds. Between
    a command finishing and the next prompt being drawn there is a gap of a few
    tens of milliseconds, and a question asked inside that gap is answered by
    hand -- `interact` sets the terminal up itself, reads a key, and puts the
    terminal back. Meanwhile the prompt starts and does the same thing from the
    other side, and the two overwrite each other: whichever loses, a keystroke
    goes to the wrong reader or the terminal is left in the wrong mode.

    Waiting turns that gap into the ordinary case, where prompt_toolkit hands
    the terminal over properly and nobody has to guess. There is nothing to
    wait for when a command is genuinely running -- that is what the ceiling is
    for, and a second's delay before a question is not a cost anyone can feel.

    And nothing to wait for either when there is no prompt_toolkit shell at
    all -- a `xonsh -c`, a test, a dumb terminal. The gap this covers is
    between one prompt and the next, so a shell that has no prompts does not
    have one; waiting the full grace there is a second spent to learn what was
    already known, and `interact` is now called twice per command rather than
    once.
    """
    import time

    if session() is None:
        return None

    end = time.monotonic() + grace
    while True:
        app = prompt()
        if app is not None or time.monotonic() >= end:
            return app
        time.sleep(PROMPT_POLL)


def _schedule(app, make) -> bool:
    """Run `make()` on the prompt's loop, in the prompt's own context.

    The context is the whole point, and it is not optional. `run_in_terminal`
    finds the application it is supposed to suspend through
    `get_app_or_none()`, which reads a `ContextVar` -- and
    `call_soon_threadsafe` copies the context of the thread that *called* it,
    which here is the worker. In the worker's context there is no application,
    so `in_terminal` quietly decides there is nothing to suspend and runs the
    callable without erasing the prompt or detaching the keyboard. Nothing
    raises. The prompt is simply still there, and whatever was written lands on
    top of it -- which looked exactly like the bug this whole module exists to
    fix, only harder to see, because the *next* keystroke redraws over the
    evidence.

    `Application.context` is the context the application is running in, which
    prompt_toolkit's own documentation points at for precisely this.

    `False` if this cannot be done properly, which the caller takes as "there is
    no prompt to write under" and says its piece the plain way. Better a line in
    the wrong place than a line written invisibly over a prompt.
    """
    context = getattr(app, "context", None)
    if context is None:
        # A prompt_toolkit that does not expose one, or an application between
        # runs. Passing `None` means "copy the caller's context", which is the
        # silent no-op above rather than a fallback.
        return False
    try:
        app.loop.call_soon_threadsafe(make, context=context)
    except (RuntimeError, TypeError):
        # The loop closed underneath us: the prompt ended between the check and
        # this call.
        return False
    return True


def write(text: str) -> None:
    """Put `text` on the terminal, wherever the terminal currently is.

    Exactly `text` and nothing else. Callers that want a line put the newline
    in it -- most do, and say so. This is the only shape that works for the two
    kinds of caller at once: a progress line is a whole line, and a chunk drained
    from a running command is whatever happened to have been written by the time
    the pipe was read, which is regularly half of one.

    Ordered with respect to other calls to `write` on the same path, and not
    across the two: a line that goes to a live prompt and a line that goes
    straight to stderr are being written by different machinery. In practice
    the paths swap only when a prompt starts or ends, which is where a reader
    expects a break anyway.
    """
    app = prompt()
    if app is None:
        _direct(text)
        return

    import asyncio

    from prompt_toolkit.application import run_in_terminal

    def show() -> None:
        _direct(text)

    def schedule() -> None:
        # Re-checked on the app's own thread: `prompt()` said yes a moment ago
        # and this runs later, by which time Enter may have been pressed.
        if not app.is_running:
            _direct(text)
            return
        asyncio.ensure_future(run_in_terminal(show))

    if not _schedule(app, schedule):
        _direct(text)


def interact(work):
    """Run `work()` with the terminal to itself, and give back what it returns.

    For everything `write` cannot express, which is now the whole of running a
    command the model asked for: printing what it is about to do, *reading the
    terminal* for the answer, and then moving the process's descriptors and
    running it. Each of those needs prompt_toolkit not to be there -- it is
    otherwise sitting on the same file descriptor in raw mode waiting for keys
    of its own, and redrawing a prompt onto a screen whose descriptor has been
    pointed at a pipe.

    Held for as long as the command takes, which is the same bargain xonsh
    makes for `ls`: the prompt is gone while a foreground command runs, and
    comes back afterwards.

    `run_in_terminal` is exactly this: it erases the prompt, detaches its input,
    puts the terminal back in cooked mode, runs the callable, and redraws
    afterwards. Everything `work` prints and reads happens inside that, in
    order, on a terminal nobody else is using.

    Called from the worker thread, so it hands the job to the prompt's own loop
    and blocks until it comes back -- blocking the *worker*, which is waiting
    for an answer anyway. With no prompt on screen there is nothing to
    coordinate with and `work` is simply called here -- but only once a prompt
    has been given a moment to appear, because a question asked in the gap
    between two prompts races the second one for the terminal. See `pending`.

    The two waits here are different questions and were once the same one, at
    the cost of running some commands twice. `HANDOVER_TIMEOUT` bounds only
    *getting started* -- the loop might have stopped, or something else might
    be holding `run_in_terminal`, and a request must not stop for ever on
    either. Once the work has begun, the wait for it to finish is unbounded,
    because how long a command takes is the command's business and no number
    here can tell "still running" from "never picked up".

    `claim` is what makes falling back safe. Both routes ask for the work
    before doing it and exactly one is ever granted, so a handover that was
    merely slow rather than dead cannot end with the command running on the
    loop *and* here -- which is what happened, complete with two banners, two
    approvals' worth of output, and a second copy running somewhere a signal
    handler cannot be installed.
    """
    app = pending()
    if app is None:
        return work()

    import asyncio
    import concurrent.futures
    import threading

    from prompt_toolkit.application import run_in_terminal

    answer: concurrent.futures.Future = concurrent.futures.Future()
    begun = threading.Event()
    lock = threading.Lock()
    taken = False

    def claim() -> bool:
        """True for the first caller only. The work is run by whoever wins."""
        nonlocal taken
        with lock:
            if taken:
                return False
            taken = True
            return True

    def run():
        # On the loop, inside `run_in_terminal`: the prompt is erased and the
        # keyboard detached, which is the whole point of going this way round.
        if not claim():
            return None
        begun.set()
        return work()

    def start() -> None:
        # Scheduled on the app's own thread, where `ensure_future` finds the
        # right loop. `run_in_terminal` hands back a future rather than a
        # coroutine, so it cannot be given to `run_coroutine_threadsafe`.
        try:
            task = asyncio.ensure_future(run_in_terminal(run))
        except BaseException as exc:  # noqa: BLE001 - handed to the caller
            begun.set()
            answer.set_exception(exc)
            return

        def finished(done) -> None:
            try:
                answer.set_result(done.result())
            except BaseException as exc:  # noqa: BLE001 - handed to the caller
                answer.set_exception(exc)

        task.add_done_callback(finished)

    if not _schedule(app, start):
        return work()

    if not begun.wait(timeout=HANDOVER_TIMEOUT) and claim():
        # Nothing started it in time and nothing else has taken it, so it is
        # ours. Worse-looking than the tidy route -- no prompt was suspended
        # for this -- and much better than never returning.
        return work()

    return answer.result()


def _direct(text: str) -> None:
    """Write to stderr, without caring whose terminal it is."""
    import sys

    try:
        sys.stderr.write(text)
        sys.stderr.flush()
    except (OSError, ValueError):
        # A closed stderr is not worth taking a request down for.
        pass
