"""Running the model's command with the terminal to itself, and keeping a copy.

Two things have to be true at once while a command the model asked for is
running: the user watches it happen, and the model is told what it wrote. The
hard part used to be that the shell was doing something else at the same time --
prompt_toolkit drawing a live prompt on another thread -- so nothing could be
moved at the level of a file descriptor without moving it for the prompt too.
That is no longer the arrangement. `tools.run_xonsh` takes the terminal for the
whole call, the way xonsh takes it for `ls`, and only gives it back afterwards.

Which means this module can do the blunt, old thing:

    dup2 a pipe onto 1 and 2, dup2 /dev/null onto 0, read the pipe, write
    every byte to the terminal and keep every byte for the model.

The blunt thing is also the complete one. A file descriptor is inherited across
`fork` and survives `exec`, so this catches `print`, a subprocess, a subprocess
of a subprocess, a shell script three levels down, and anything that writes to
descriptor 1 without consulting `sys.stdout` -- which is most real programs and
was the whole difficulty before.

And it is where the *no pty* guarantee comes from, which is otherwise a thing
you have to keep asking xonsh for and keep being told no. Descriptor 1 is a
pipe, so `isatty` is false for the command and for everything beneath it. No
alternate screen, no progress bar redrawing over itself, no colour, and no
pager stopping to be read a page at a time. Not "we asked for it to be
captured" -- there is genuinely no terminal there.

The one thing lost with it is job control, and it is lost harmlessly. Xonsh
hands the terminal to a command's process group with `tcsetpgrp` on descriptor
*2*, so a pipe there means that call fails -- gracefully, it is written to
expect a descriptor that is not a tty -- and the command never becomes the
terminal's foreground group. Normally that would be a problem twice over:
Ctrl+C would not reach it, and it would take `SIGTTIN`/`SIGTTOU` the moment it
touched the terminal. The second never applies, because the command has no
terminal on any descriptor to touch. The first is handled a level up, by
`take_sigint`: the signal comes to this process, `run_in_session` catches the
`KeyboardInterrupt`, and `interrupt_children` passes it on. See both.
"""

from __future__ import annotations

import os
import signal
import sys
import threading
from contextlib import contextmanager

#: How long the reader gets to finish once both ends have been put back. Only
#: reached when something still holds the write end open -- a child that
#: backgrounded itself -- and a request must not stop for ever on one of those.
DRAIN_TIMEOUT = 5.0

#: What to set, and to what, so that nothing the model runs stops to be read a
#: page at a time. Belt and braces rather than load-bearing now: off a terminal
#: `git` and `systemctl` do not reach for a pager at all. Kept because one that
#: is *configured* to page regardless does not fail noisily -- it fills a screen
#: nobody is looking at and waits for a keypress that is never coming. `cat`
#: rather than emptiness: an unset `PAGER` means "use the default", which is
#: `less`, and `git` reads its own variable first.
PAGERS = {"PAGER": "cat", "GIT_PAGER": "cat", "SYSTEMD_PAGER": "cat"}

#: Python block-buffers its output when it is not a terminal, so a script that
#: prints as it works arrives in one lump when it exits. Correct for the model,
#: which reads the result whole, and useless for the user watching it run. This
#: buys the live view back for Python children. There is no general form of it:
#: a C program's buffering is its own business, so anything else that does not
#: flush stays quiet until it finishes.
UNBUFFERED = {"PYTHONUNBUFFERED": "1"}


def terminal_size() -> dict:
    """`$COLUMNS`/`$LINES` for the real terminal, as a program with none reads them.

    Nothing on the far side of the pipe has a terminal to measure, so
    `shutil.get_terminal_size()` there answers 80x24 and a `git diff`, a `ps
    aux` or a `--help` comes back wrapped for a screen half the width of the one
    in front of the user. These two variables are where a program with no tty
    looks instead, and the real size is on this side to tell it.

    The user's own width rather than something deliberately wide, because they
    are reading this output too -- it goes to their terminal as it is produced,
    and a hundred and forty columns of it on a hundred-column screen wraps
    twice.
    """
    for fd in (1, 2, 0):
        try:
            size = os.get_terminal_size(fd)
        except (OSError, ValueError):
            continue
        return {"COLUMNS": str(size.columns), "LINES": str(size.lines)}
    return {}


def take_sigint():
    """Make Ctrl+C raise, for as long as the command runs. Gives back the undo.

    Without this, Ctrl+C does nothing at all -- which is not xonsh's doing and
    is worth writing down, because everything about it points the other way.

    prompt_toolkit asks asyncio to handle SIGINT for it, so that Ctrl+C at a
    prompt is a *key* rather than an exception: `add_signal_handler` leaves
    `asyncio._sighandler_noop` installed as the Python handler and arranges for
    the loop to be woken and to call prompt_toolkit's binding later, from the
    loop. That is exactly right while the loop is going round.

    The command runs on the loop -- `terminal.interact` hands it to
    prompt_toolkit's own thread through `run_in_terminal`, which is what gets
    the prompt erased and the keyboard detached -- so while it runs, the loop
    is not going round. Ctrl+C then does nothing whatsoever: the handler is a
    no-op, and the callback that would have meant something is queued behind
    the command it was meant to interrupt. It arrives afterwards, at the next
    prompt, as a keystroke nobody typed.

    Xonsh's own commands never meet this, and the asymmetry is the tell: `ls`
    runs after `Application.run()` has returned and put the default handler
    back. Ours runs inside it. So take the handler back for the duration and
    put it back after -- both cheap, and the window is exactly one command.

    Only the main thread may install one. Off it there is nothing to take:
    Python delivers to the main thread regardless, so a handler here would not
    fire anyway.

    The children are signalled from inside the handler rather than from
    whoever catches the `KeyboardInterrupt`, and the difference is measurable.
    Raising only starts an exception on its way up, and how long it takes to
    get out of xonsh's pipeline machinery depends on where it was when the
    signal landed -- for `a | b` it was most of three seconds, during which the
    command carried on printing. A plain xonsh has no such delay because it
    does not do this at all: the pipeline is the terminal's foreground group,
    so the kernel signals it directly and instantly. Signalling first is the
    closest this can get to that, and it puts the two within a keystroke of
    each other.

    Which is why nothing downstream forwards it: by the time anyone catches
    the `KeyboardInterrupt`, the children have already had their signal.
    """
    # Imported here rather than inside the handler, which runs at a moment
    # nobody chose -- possibly midway through somebody else's import.
    from xonsh.built_ins import XSH  # noqa: F401

    def raise_it(signum, frame):
        interrupt_children()
        raise KeyboardInterrupt

    try:
        previous = signal.signal(signal.SIGINT, raise_it)
    except ValueError:
        return lambda: None

    def undo() -> None:
        try:
            signal.signal(signal.SIGINT, previous)
        except ValueError:
            pass

    return undo


def interrupt_children() -> None:
    """Pass a Ctrl+C on to whatever the command started.

    The signal arrives here rather than there. Xonsh puts an interactive
    command in a process group of its own, and the `tcsetpgrp` that would have
    made that group the terminal's foreground one cannot succeed while
    descriptor 2 is a pipe -- so the terminal sends `SIGINT` to *this* process
    group, `take_sigint`'s handler raises `KeyboardInterrupt` on the main
    thread, and the child notices nothing at all.

    Hence forwarding it by hand. Groups rather than pids, so that a pipeline and
    anything it spawned go together, and never this shell's own group however
    the lookup turns out. Best effort throughout: a process that has already
    exited between being listed and being signalled is the ordinary case, not an
    error, and an interrupt must not raise on its way out.
    """
    from xonsh.built_ins import XSH

    ours = os.getpgrp()
    groups = set()
    # `lastcmd` rather than `last`: they are the same pipeline, and reading the
    # older name prints a DeprecationWarning -- onto the terminal the user is
    # watching and into the copy the model is about to read, which is a poor
    # way to answer a Ctrl+C.
    for proc in getattr(getattr(XSH, "lastcmd", None), "procs", None) or ():
        pid = getattr(proc, "pid", None)
        if not pid:
            continue
        try:
            group = os.getpgid(pid)
        except OSError:
            continue
        if group != ours:
            groups.add(group)

    for group in groups:
        try:
            os.killpg(group, signal.SIGINT)
        except OSError:
            pass


@contextmanager
def captured(sink):
    """Point descriptors 0, 1 and 2 somewhere else for the duration.

    Stdout and stderr become one pipe, read by a thread that writes every byte
    twice: to `sink`, which is the model's copy, and to the terminal, which is
    the user's. One pipe rather than two because a command's output is one
    thing -- a compiler that fails says so on 2, and interleaving them after the
    fact is guesswork.

    Stdin becomes `/dev/null`, and that is not tidiness. Xonsh does not redirect
    descriptor 0, so otherwise a command the model runs inherits the *user's
    terminal* and reads their keystrokes: `sudo` asks for a password into a
    prompt nobody is expecting, `git commit` waits for an editor that is not
    coming, and a bare `cat` never returns. `/dev/null` turns every one of those
    from a wedged session into an error the model can read and act on.

    The user's copy goes straight to the descriptor, and to the *saved* second
    one rather than the first. Directly, because nothing is drawing on the
    terminal while this is open -- that is the caller's side of the bargain, and
    it is what makes a plain write correct here rather than the thing that used
    to scribble over a live prompt. Stderr, because everything pai puts on
    screen goes there, so that `: what is my ip > answer.txt` still writes the
    answer and not the output of whatever was run to find it.
    """
    from xonsh.built_ins import XSH

    env = getattr(XSH, "env", None)
    restore_env = _environment(
        env, {**PAGERS, **UNBUFFERED, **terminal_size()}
    )
    restore_sigint = take_sigint()

    saved: dict[int, int] = {}
    read_fd = write_fd = devnull = -1
    reader: threading.Thread | None = None
    python_streams = (sys.stdout, sys.stderr)
    try:
        # Whatever Python is still holding, before the descriptors underneath
        # it move. A buffered line flushed after the swap would land in the
        # model's copy of a command it came before.
        _flush()
        # One at a time and recorded as they are taken, so that a failure
        # halfway through still has something to put back and to close.
        for fd in (0, 1, 2):
            saved[fd] = os.dup(fd)
        read_fd, write_fd = os.pipe()
        devnull = os.open(os.devnull, os.O_RDONLY)
        reader = threading.Thread(
            target=_relay, args=(read_fd, saved[2], sink), daemon=True
        )
        reader.start()

        os.dup2(devnull, 0)
        os.dup2(write_fd, 1)
        os.dup2(write_fd, 2)
        # And `print` too, which is not the same question. Moving a descriptor
        # only redirects what is written *through* it, and `sys.stdout` is not
        # obliged to be: xonsh wraps it around every command it runs, and a test
        # harness capturing output replaces it outright with a file of its own.
        # Either would write past the pipe and out of the model's copy. Bound to
        # the descriptors as they now are, so both levels agree.
        sys.stdout, sys.stderr = _on(1), _on(2)
        yield
    finally:
        _flush()
        sys.stdout, sys.stderr = python_streams
        for fd, backup in saved.items():
            os.dup2(backup, fd)
        # Every write end has to be shut before the reader can see the end of
        # the stream: the two above were copies of `write_fd`, and putting the
        # saved descriptors back is what closed them.
        _close(write_fd, devnull)
        # `read_fd` and the terminal it relays to are the reader's, and it
        # closes them itself -- which matters when it is still going, because
        # something the command left running can hold the write end open past
        # the wait below. Closing them from here would be closing them under a
        # live thread, and descriptor numbers get reused.
        if reader is None:
            _close(read_fd, saved.get(2, -1))
        else:
            reader.join(timeout=DRAIN_TIMEOUT)
        _close(*(fd for number, fd in saved.items() if number != 2))
        # Last, so that a Ctrl+C arriving during the unwind above is still ours
        # to catch rather than a keystroke queued for the next prompt.
        restore_sigint()
        restore_env()


def _close(*fds: int) -> None:
    """Close each of `fds`, and never mind the ones that were never opened."""
    for fd in fds:
        if fd < 0:
            continue
        try:
            os.close(fd)
        except OSError:
            pass


def _on(fd: int):
    """A text stream writing to `fd`, whatever `fd` currently points at.

    `closefd=False` because the descriptor is not this object's to close -- it
    is the session's, borrowed for the length of one command. Written straight
    through rather than buffered, so that a line printed a second before the
    next one is shown a second before the next one.
    """
    import io

    return io.TextIOWrapper(
        io.FileIO(fd, "w", closefd=False), write_through=True, errors="replace"
    )


def _relay(read_fd: int, terminal_fd: int, sink) -> None:
    """Everything arriving on `read_fd`, to the terminal and to `sink`.

    Byte for byte and as it arrives. There is no line buffering here and there
    used to be: shown a line at a time only mattered when each write cost a
    prompt redraw, and no prompt is being drawn. A program that writes half a
    line and waits -- a question, a progress bar -- reaches the screen now
    rather than when it happens to finish the line.

    Both descriptors are this thread's to close, and closing `read_fd` on the
    way out is load-bearing rather than tidy. The only way to be here after the
    request has ended is a command that outlived it -- a Ctrl+C that its child
    ignored, something backgrounded -- and dropping the last read end is what
    finally stops it: the next write gets `EPIPE`, which is the ordinary way a
    program is told nobody is listening. Staying open would leave it filling a
    pipe until it blocked on one nobody would ever drain.

    Which is also what a closed sink means, and why it is a reason to stop
    rather than an error: the sink is the model's copy, it is closed when the
    request that wanted it is over, and there is nothing left to relay it to.
    """
    try:
        while True:
            try:
                chunk = os.read(read_fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            try:
                sink.write(chunk)
            except (ValueError, OSError):
                return
            _write_all(terminal_fd, chunk)
    finally:
        _close(read_fd, terminal_fd)


def _write_all(fd: int, data: bytes) -> None:
    """`os.write` until it is all written, and never mind if it cannot be.

    A short write is legal and a closed terminal is possible, and neither is
    worth taking a request down for -- the model's copy is already safe in the
    sink by the time this is called.
    """
    while data:
        try:
            written = os.write(fd, data)
        except OSError:
            return
        data = data[written:]


def _flush() -> None:
    """Push whatever Python is holding down to the descriptors."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (AttributeError, OSError, ValueError):
            pass


def _environment(env, settings: dict):
    """Apply `settings` to `env`, and give back the call that undoes it.

    Undoing means putting back what was there, including the difference between
    a variable that was empty and one that was never set -- the second is what
    `PAGER` has to go back to, since an empty `PAGER` and no `PAGER` mean
    different things to the programs that read it.

    The environment belongs to the whole session rather than to this call, which
    used to be a real bargain and is now barely one: the terminal is held for
    the duration, so there is no prompt for the user to start a command from
    while these are in place.
    """
    if env is None:
        return lambda: None

    missing = object()
    before = {name: env.get(name, missing) for name in settings}
    env.update(settings)

    def undo() -> None:
        for name, value in before.items():
            if value is missing:
                env.pop(name, None)
            else:
                env[name] = value

    return undo
