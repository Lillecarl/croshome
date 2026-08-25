"""`run_xonsh`: let the model run things, with you saying yes first.

Deliberately not sandboxed. The code runs in the *live* session -- xonsh's own
execer, xonsh's own context -- so `cd` sticks, `$VARS` set here are set for the
next prompt, and Python names defined here are still bound afterwards. A
subprocess would be safer and would also make the tool useless: an assistant at
your prompt that cannot change your directory is a search engine.

The control is the approval, not a boundary. Every call shows the exact source
and waits for a `y` -- unless the overseer next door has been turned on to
answer for the user, which is off by default and documented there. Refusing is a
normal outcome, reported back to the model as a result rather than an error, so
it can suggest something else.

The one hard rule is that the approval must be real: no tty means no human to
ask, so the tool declines rather than running unattended. That holds with an
overseer too -- it stands in for the question, not for the person.

Three things happen per call, in this order, and only the last one takes the
terminal away from the prompt:

* the code goes on screen, straight away and before the reviewer is even
  asked -- an ordinary write above a live prompt, which `terminal.write` knows
  how to do without disturbing what is half-typed;
* it is judged: the overseer first, then the user, who gets a window to veto
  an approval or a question to answer if nobody approved;
* it runs.

Only that last step is held. prompt_toolkit is asked to stand aside -- which
erases the prompt, detaches its input and puts the terminal back in cooked
mode -- and for as long as it does, this is an ordinary foreground command like
any other the user runs. Which is what lets `streams` simply move descriptors
0, 1 and 2, lets Ctrl+C mean what it means everywhere else, and lets the output
be written to the terminal rather than negotiated with a prompt still drawing
on it.

The split is not cosmetic. All three were once one hold, which meant the prompt
stayed erased for as long as the *question* went unanswered: walk away from one
and the shell was unusable until you came back and pressed a key. Deciding and
running want the terminal for quite different lengths of time, so they take it
separately.
"""

from __future__ import annotations

import builtins
import io
import os
import sys
import tempfile
import termios
import tty

#: What a typed-out `yes` looks like, where a whole line had to be read.
#: Anything else -- including a bare Enter -- is no.
_YES = frozenset({"y", "yes"})

#: What a *keystroke* yes looks like. Just the one key, and nothing forgiving:
#: on this path there is no Enter to take a slip back before it counts.
_YES_KEYS = frozenset({"y", "Y"})

#: And what a keystroke *no* looks like, for the window where silence is a yes.
#: Only these stop it; every other key means "run it now".
_NO_KEYS = frozenset({"n", "N"})

#: Asked when nobody has approved on the user's behalf. No deadline: with no
#: reviewer standing in, an unanswered question must not become a yes.
_QUESTION = "run this? [y/N] "

#: Asked when the overseer has already approved. The command is going to run,
#: and this is the window in which to stop it.
_VETO = "running in {seconds:.0f}s -- press n to cancel, any key to run now "

#: What that window is, in seconds. `$XONTRIB_PAI_APPROVAL_SECONDS` overrides
#: it. Long enough to read a line and react, short enough that an approved
#: command does not feel stalled behind a countdown.
APPROVAL_SECONDS = 5.0

#: The setting that overrides it. Zero or less runs approved commands with no
#: window at all, which is the right answer for anyone who trusts the reviewer
#: and finds the pause tiresome.
APPROVAL_VAR = "XONTRIB_PAI_APPROVAL_SECONDS"

#: How much of a command's output to hand back. Enough for a build log's tail,
#: bounded so one `find /` cannot fill the context window.
MAX_OUTPUT = 8000


def _ask(question: str) -> str:
    """`input`, looked up when called rather than captured at import.

    A default argument would bind the real `builtins.input` once and for all,
    which makes the approval prompt untestable -- and untestable is not a state
    the only safety control in this module may be in.
    """
    return builtins.input(question)


def _read_key(prompt: str, seconds: float | None = None) -> str | None:
    """Show `prompt`, take a single keystroke, and echo it.

    `None` where there is no terminal to take a keystroke from -- a pipe, a
    captured stdin -- which is the caller's cue to read a whole line instead.
    Reported rather than papered over, because "one key" and "one line" are
    different agreements about what counts as consent.

    `seconds` puts a deadline on it, and `""` is what came back when nobody
    pressed anything. Without one this waits for ever, which is right for a
    question nobody has answered on the user's behalf and wrong for a window
    whose whole purpose is to close.
    """
    try:
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
    except (AttributeError, ValueError, OSError, termios.error):
        return None

    print(prompt, end="", file=sys.stderr, flush=True)
    # `None` until the terminal is known to be in the state this function put
    # it in. Everything before that point fails too fast for anyone else to
    # have taken the terminal over, so a failure there restores unconditionally.
    cbreak = None
    key = ""
    try:
        tty.setcbreak(fd)
        # Whatever was typed while the model was thinking is still sitting in
        # the terminal's queue, and with no Enter to confirm, the first queued
        # byte would *be* the answer. Only a key pressed after the question is
        # on screen may count as approval.
        termios.tcflush(fd, termios.TCIFLUSH)
        cbreak = termios.tcgetattr(fd)
        if seconds is None or _waiting(fd, seconds):
            key = sys.stdin.read(1)
    finally:
        _restore(fd, saved, cbreak)

    # cbreak turns the terminal's own echo off, so the answer appears on screen
    # only because of this; the newline ends the prompt line either way.
    print(key if key.isprintable() else "", file=sys.stderr, flush=True)
    return key


def _waiting(fd: int, seconds: float) -> bool:
    """Is there a keystroke to read within `seconds`?

    `select` rather than a read with a timer, because the read has to not
    happen at all when nobody pressed anything: a key arriving a moment after
    the window closed belongs to the next prompt, not to this question.
    """
    import select

    if seconds <= 0:
        return False
    try:
        ready, _, _ = select.select([fd], [], [], seconds)
    except (OSError, ValueError):
        return False
    return bool(ready)


def _restore(fd: int, saved, ours) -> None:
    """Put the terminal back as it was -- unless it is no longer ours to put back.

    The gap being closed here is long: it is however long the user takes to
    answer, and a shell does not stand still for it. `interact` runs the
    question here on the worker thread when no prompt is on screen, which is
    the right call at the time -- but the reason there is no prompt is usually
    that a command is finishing, and when it finishes prompt_toolkit draws a
    prompt and puts the terminal into raw mode. Writing `saved` over that hands
    a live prompt a *canonical* terminal, and canonical is not a cosmetic
    difference: the driver swallows keystrokes into a line buffer prompt_toolkit
    never reads, and it never asks about the mode again, so the shell stops
    answering the keyboard for good. You get a terminal that echoes what you
    type and does nothing with it.

    So: put back what we changed, unless somebody else has changed it since --
    in which case theirs is the current truth and ours is stale. `ours` is what
    the terminal looked like immediately after `setcbreak`, which is exactly the
    state a restore is entitled to overwrite.

    A window of a few microseconds remains, between the comparison and the
    write. That one is not worth more machinery; the one this closes was
    seconds wide and left the shell deaf.
    """
    try:
        if ours is not None and termios.tcgetattr(fd) != ours:
            return
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    except (ValueError, OSError, termios.error):
        # The terminal went away while the question was out. Nothing to put
        # back, and an approval must not raise on the way out.
        pass


def banner(code: str, justification: str) -> str:
    """What the user is shown before a command runs.

    One function rather than one per path: an approval the overseer gave and an
    approval the user gave must look the same on the terminal, because the only
    thing standing between a bad command and a running one is somebody reading
    it. Two copies of this would drift, and the way they would drift is one of
    them going quiet.
    """
    rule = "-" * 60
    why = f"\n\nwhy: {justification.strip()}" if justification.strip() else ""
    return f"\n{rule}\npai wants to run:\n\n{code.rstrip()}{why}\n{rule}"


def _said_yes() -> bool:
    """Ask, and answer. `False` for anything but an explicit yes."""
    try:
        key = _read_key(_QUESTION)
        if key is not None:
            return key in _YES_KEYS
        return _ask(_QUESTION).strip().lower() in _YES
    except (EOFError, KeyboardInterrupt):
        print(file=sys.stderr)
        return False


def approval_seconds() -> float:
    """How long the veto window is, per `$XONTRIB_PAI_APPROVAL_SECONDS`."""
    from .integration import env_get

    try:
        return float(env_get(APPROVAL_VAR))
    except (TypeError, ValueError):
        return APPROVAL_SECONDS


def _not_vetoed(seconds: float) -> bool:
    """Give the user `seconds` to stop a command the overseer approved.

    A window rather than a question, and the difference is the default. Somebody
    has already said yes on the user's behalf; this is the chance to disagree,
    so silence means the thing that was approved happens. Only `n` stops it --
    any other key just runs it now instead of at the end of the countdown,
    because a user who has read the command and is reaching for the keyboard
    wants it to get on with it.

    With no terminal to read from there is nobody to veto and nothing to wait
    for, so it goes ahead. That case is already unreachable -- `run_xonsh`
    refuses without a console before any of this -- and answering it here means
    the window can never be the thing that silently blocks a shell.
    """
    try:
        key = _read_key(_VETO.format(seconds=seconds), seconds=seconds)
    except (EOFError, KeyboardInterrupt):
        # Ctrl+C in the window is the clearest "no" there is.
        print(file=sys.stderr)
        return False
    if key is None:
        return True
    return key not in _NO_KEYS


def _judged(approved_already: bool) -> bool:
    """Take the answer, in whichever way the reviewer's verdict calls for.

    One hold of the terminal, and it is not the same hold the command gets.
    Deciding needs the keyboard for as long as a person takes; running needs
    the process's descriptors for as long as a command takes. Fusing them, as
    this once did, meant an unanswered question kept the prompt erased and the
    shell unusable until somebody came back and pressed a key.

    The code itself is already on screen by now, written before the reviewer
    was even asked -- see `run_xonsh`. Both paths ask underneath it.
    """
    from . import terminal

    if approved_already:
        seconds = approval_seconds()
        if seconds <= 0:
            return True
        return terminal.interact(lambda: _not_vetoed(seconds))
    return terminal.interact(_said_yes)


def run_in_session(code: str) -> str:
    """Execute xonsh source in the live session and return what it printed.

    Both audiences at once, which `streams.captured` is what does: the user
    watches it happen on their terminal, and what comes back here is the same
    bytes for the model.

    Passed through `legible` on the way out even though there is no terminal on
    the far side of that pipe to provoke one. Most programs stop drawing for a
    screen they cannot see, and the ones that do not -- anything run with
    `--color=always`, a progress bar that redraws unconditionally -- are exactly
    the ones worth tidying.
    """
    from xonsh.built_ins import XSH

    from . import streams
    from .legible import legible

    note = ""
    sink = tempfile.TemporaryFile(mode="w+b")
    try:
        with streams.captured(sink):
            try:
                XSH.execer.exec(code, glbs=XSH.ctx, filename="<pai>")
            except SystemExit:
                # `exit` inside the tool must not take the shell down with it.
                note = "\n[the code called exit; the shell is still running]"
            except KeyboardInterrupt:
                # The children were already signalled, by the handler that
                # raised this; see `streams.take_sigint`. All that is left is
                # to say so, so the model reads a stopped command as stopped
                # rather than as one that produced less than it meant to.
                note = "\n[interrupted]"
            except BaseException as exc:  # noqa: BLE001 - reported, not raised
                note = f"\n{type(exc).__name__}: {exc}"
        # Read after the descriptors are back where they belong, so everything
        # written has been flushed and relayed.
        sink.seek(0)
        return legible(sink.read().decode(errors="replace")) + note
    finally:
        sink.close()


def truncate(text: str, limit: int = MAX_OUTPUT) -> str:
    """Keep the tail: the end of a log is where the error is."""
    if len(text) <= limit:
        return text
    return f"[... {len(text) - limit} characters trimmed ...]\n{text[-limit:]}"


def has_console() -> bool:
    """Is there a human to ask?"""
    try:
        return sys.stdin is not None and sys.stdin.isatty()
    except (AttributeError, ValueError, io.UnsupportedOperation):
        return False


def run_xonsh(justification: str, code: str) -> str:
    """Run xonsh code in the user's live shell session.

    This is the user's real shell: the working directory, environment variables
    and Python names it changes stay changed for their next prompt. xonsh syntax
    is available, so shell commands (`ls -la`), Python, and the mixed forms
    (`@(expr)`, `$(cmd)`, `![cmd]`) all work.

    The code is shown before it runs and has to be approved, either by the user
    answering or by a reviewer answering on their behalf. Write it so it is
    obvious at a glance what it does, and prefer one focused command over a long
    script. If a call is declined, do not simply resend it.

    Args:
        justification: Why this command, in one sentence -- what you are trying
            to find out or change, and why this is the way to do it. Whoever
            approves the call reads it next to the code, so it must describe
            what the code actually does.
        code: xonsh source to execute.

    Returns:
        Whatever the code wrote to stdout and stderr, or a note that it was
        declined.
    """
    # Before anything else, including the review: no terminal means nobody is
    # watching the output, and this tool exists to do things in front of people.
    if not has_console():
        return (
            "Declined: no terminal is attached, so the user cannot be asked. "
            "Nothing was run."
        )

    from . import overseer, terminal
    from .agent import asked
    from .progress import note

    # First, and before the review rather than after it, which is the whole
    # shape of this function. The user reads the command while the reviewer
    # reads it, instead of watching a reviewer deliberate over something they
    # have not been shown; and by the time anything is asked, the thing being
    # asked about is already on screen above the question.
    #
    # `terminal.write` rather than `print`, because there is a prompt on screen
    # and this is another thread: it goes above the prompt and leaves whatever
    # is half-typed alone.
    terminal.write(banner(code, justification) + "\n")

    # `asked()` is the line the user typed to start this turn -- the one part
    # of the review the party under review did not write. See `overseer`.
    verdict = overseer.review(code, justification, os.getcwd(), asked())
    approved = False
    if verdict is not None:
        if verdict.safe:
            note(f"overseer approved: {verdict.reason}")
            approved = True
        else:
            # A refusal is advice, not a veto: it falls through to the
            # question, with its reason on screen to disagree with.
            note(f"overseer refused: {verdict.reason}")

    if not _judged(approved):
        return "The user declined to run that. Ask what they would prefer."

    # And only now is the terminal taken for the command, which is the only
    # part that needs it: `streams.captured` moves this process's descriptors,
    # and doing that while a prompt is live moves them for the prompt too.
    return truncate(terminal.interact(lambda: run_in_session(code)))
