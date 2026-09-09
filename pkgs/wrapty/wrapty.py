"""Minimal PTY wrapper. Forwards stdin, and any text sent over a JSON-RPC
control socket, to a child process; the child's stdout goes straight to
our stdout."""

import asyncio
import fcntl
import os
import pty
import random
import secrets
import signal
import sys
import termios
import time
import traceback
import tty

from jsonrpc import Dispatcher
from jsonrpc.exceptions import (
    JSONRPCDispatchException,
    JSONRPCMethodNotFound,
    JSONRPCServerError,
)
from jsonrpc.jsonrpc2 import JSONRPC20Request, JSONRPC20Response

# Apps that distinguish typed input from a paste (Claude Code's own input box
# included) treat a burst of text ending in Enter, delivered in one go, as a
# paste and don't submit it. Sending Enter as a separate write shortly after
# the text avoids that.
ENTER_DELAY = 0.05
ENTER_DELAY_JITTER = float(os.environ.get("WRAPTY_ENTER_DELAY_JITTER", "0.4"))

# The same paste-vs-typed distinction applies within the text itself, not
# just at the trailing Enter: an instant multi-hundred-byte write is trivial
# to tell apart from human typing, even once split by write_master's own
# partial-write handling, since those chunks still land within microseconds
# of each other. Delivering the text a few bytes at a time with a real delay
# between chunks avoids that. A perfectly uniform delay is itself a tell, so
# both this and ENTER_DELAY are jittered rather than fixed.
TYPE_CHUNK_SIZE = int(os.environ.get("WRAPTY_TYPE_CHUNK_SIZE", "16"))
TYPE_CHUNK_DELAY = float(os.environ.get("WRAPTY_TYPE_CHUNK_DELAY", "0.02"))
TYPE_CHUNK_JITTER = float(os.environ.get("WRAPTY_TYPE_CHUNK_JITTER", "0.5"))


def _jittered(base, frac):
    return random.uniform(base * (1 - frac), base * (1 + frac))

# Below this usage %, the compact tool refuses to fire — compacting a mostly
# empty context throws away history for no benefit.
MIN_COMPACT_PCT = float(os.environ.get("WRAPTY_MIN_COMPACT_PCT", "25"))

# How long to let the wrapped session's TUI settle after a Stop event before
# typing /compact -- the turn having ended is necessary but the terminal may
# still be mid-redraw for a moment.
COMPACT_SETTLE_DELAY = float(os.environ.get("WRAPTY_COMPACT_SETTLE_DELAY", "1"))
# How often to poll context usage for proof compaction actually ran, and the
# cap on how long to wait before giving up and resuming anyway.
COMPACT_POLL_INTERVAL = float(os.environ.get("WRAPTY_COMPACT_POLL_INTERVAL", "2"))
COMPACT_MAX_WAIT = float(os.environ.get("WRAPTY_COMPACT_MAX_WAIT", "120"))
# How long to let the session settle after a temporary stop before typing the
# agent back to. The queued input submits at the turn boundary, so this only
# has to cover that landing, not the command itself finishing.
RESUME_SETTLE_DELAY = float(os.environ.get("WRAPTY_RESUME_SETTLE_DELAY", "2"))
CONTINUE_TEXT = os.environ.get("WRAPTY_CONTINUE_TEXT", "Continue with your task.")


# A full-screen TUI (the wrapped child) can leave the real terminal in a
# mode this wrapper's raw pass-through never interprets or tracks --
# alternate screen buffer, hidden cursor, mouse tracking, bracketed paste
# (Claude Code's own paste-vs-type detection, see ENTER_DELAY above, implies
# it drives at least the last of these). The child is never told a suspend
# is happening (the suspend keystroke is intercepted before it ever reaches
# the child), so it gets no chance to leave those modes cleanly on its own.
# Resetting them by hand before actually stopping is what hands the shell
# back a terminal it can actually use, rather than one still sitting behind
# whatever mode the TUI last set.
TERMINAL_RESET = (
    b"\x1b[?1049l"  # exit alternate screen buffer
    b"\x1b[?25h"  # show cursor
    b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l"  # mouse tracking off
    b"\x1b[?2004l"  # bracketed paste off
)


# Never write a diagnostic to stderr while the child runs. stderr is the real
# terminal, and the child is a full-screen TUI that tracks what it drew there.
# Text it did not write leaves its model of the screen wrong, and the display
# stays corrupt until something forces a full repaint -- a resize, in practice.
# So every traceback goes to this file instead, next to the control socket.
# _run() sets it; before that there is no child and stderr is still safe.
_log_path = None


def _write_log(text):
    if _log_path is None:
        sys.stderr.write(text)
        return
    try:
        with open(_log_path, "a") as f:
            f.write(text)
    except OSError:
        pass  # a lost diagnostic is not worth taking the session down for


def _log_exception(context):
    """Record the exception being handled, with a timestamp and a note of
    where it came from."""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    _write_log(f"[{stamp}] {context}\n{traceback.format_exc()}\n")


def _on_loop_exception(loop, context):
    """The event loop's last line of defence. Anything that escapes a task, a
    reader callback or a signal handler arrives here; asyncio's own handler
    would print it to stderr."""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    message = context.get("message", "unhandled exception in the event loop")
    text = f"[{stamp}] {message}\n"
    exception = context.get("exception")
    if exception is not None:
        text += "".join(traceback.format_exception(exception))
    _write_log(text)


def _sync_winsize(stdin_fd, master_fd):
    try:
        winsize = fcntl.ioctl(stdin_fd, termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        return
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)


async def _dispatch(request_str, dispatcher):
    """Equivalent to JSONRPCResponseManager.handle(), except a dispatcher
    method may be a coroutine function -- awaited here, so its RPC caller's
    connection stays open (and its response arrives) only once the method
    has genuinely finished, not before. send() relies on this: the caller
    gets "ok" when the text has actually been typed, not when typing merely
    started. Scoped to this project's actual usage (single, non-batch
    requests, always with an id) rather than the full spec."""
    request = JSONRPC20Request.from_json(request_str)
    try:
        method = dispatcher[request.method]
    except KeyError:
        return JSONRPC20Response(_id=request._id, error=JSONRPCMethodNotFound()._data)

    try:
        result = method(*request.args, **request.kwargs)
        if asyncio.iscoroutine(result):
            result = await result
    except JSONRPCDispatchException as e:
        return JSONRPC20Response(_id=request._id, error=e.error._data)
    except Exception as e:
        data = {"type": e.__class__.__name__, "args": e.args, "message": str(e)}
        return JSONRPC20Response(_id=request._id, error=JSONRPCServerError(data=data)._data)
    return JSONRPC20Response(_id=request._id, result=result)


async def _handle_client(reader, writer, dispatcher):
    """One control socket connection. Nothing escapes: this runs as an asyncio
    server callback, so an exception here reaches the loop handler, and the
    caller going away mid-call is ordinary rather than exceptional. A
    statusline or hook process that exits before reading its reply is the
    common case -- Claude Code starts and abandons those freely."""
    try:
        async for line in reader:
            # errors="replace" so a truncated multi-byte character becomes a
            # parse error the caller is told about, not an exception here.
            response = await _dispatch(line.decode(errors="replace"), dispatcher)
            writer.write(response.json.encode() + b"\n")
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass  # the caller left before reading its reply; nothing to report
    except Exception:
        _log_exception("control socket connection")
    finally:
        writer.close()


async def _run(argv):
    wapty_id = secrets.token_hex(4)

    master_fd, slave_fd = pty.openpty()

    # A NEW session for the child gives it clean isolation from the outer
    # terminal (see _suspend_self below), but a solitary session leader's
    # own process group is -- by POSIX's own definition -- orphaned: no
    # other process in that session, in a different group, is the parent
    # of one of its members. A STOP-class signal (SIGTSTP included) sent to
    # an orphaned group is discarded outright, unconditionally, regardless
    # of who sends it. Claude Code's own native suspend keystroke does
    # exactly that: self-sends SIGTSTP. Run as a lone session leader, that
    # is a silent no-op -- it prints its own "suspended" banner and just
    # keeps running, wedged, since nothing really stopped it and nothing
    # will ever send the SIGCONT it's presumably waiting on.
    #
    # A shepherd process fixes this the way a real shell fixes it for its
    # own foreground jobs: it becomes the session leader and stays alive
    # (never exec'ing), and the real child runs as ITS child, in a
    # different process group within that same session. That is the
    # textbook non-orphan bridge, so the child's self-SIGTSTP now actually
    # stops it, as a real, observable kernel event.
    #
    # It's observable to the *shepherd*, though, not to us -- only a
    # process's direct parent can wait()/waitid() on it, and the shepherd
    # is the child's parent now, not this process. child_state_r is how
    # the shepherd forwards what it sees (one byte, b"T" stopped / b"C"
    # continued) so this process can mirror it (see _on_child_state below).
    read_child_pid, write_child_pid = os.pipe()
    child_state_r, child_state_w = os.pipe()
    shepherd_pid = os.fork()
    if shepherd_pid == 0:
        os.close(read_child_pid)
        os.close(child_state_r)
        os.close(master_fd)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

        child_pid = os.fork()
        if child_pid == 0:
            os.close(child_state_w)
            try:
                os.setpgid(0, 0)
            except OSError:
                pass
            os.dup2(slave_fd, 0)
            os.dup2(slave_fd, 1)
            os.dup2(slave_fd, 2)
            if slave_fd > 2:
                os.close(slave_fd)
            os.environ["WAPTY_ID"] = wapty_id
            os.execvp(argv[0], argv)
            os._exit(127)

        # Both sides set the child's pgid -- classic fork/setpgid race
        # (APUE 9.9): whichever of shepherd or child runs first, it's
        # right by the time either depends on it.
        try:
            os.setpgid(child_pid, child_pid)
        except OSError:
            pass
        os.tcsetpgrp(slave_fd, child_pid)
        os.close(slave_fd)
        os.write(write_child_pid, str(child_pid).encode())
        os.close(write_child_pid)

        def _shepherd_on_sigchld(signum, frame):
            # WNOWAIT: peek without reaping, so this can't race the real
            # termination wait below -- that one call is the only one
            # allowed to actually consume the child's exit.
            try:
                info = os.waitid(
                    os.P_PID, child_pid, os.WNOHANG | os.WSTOPPED | os.WCONTINUED | os.WNOWAIT
                )
            except ChildProcessError:
                return
            if info is None:
                return
            if info.si_code == os.CLD_STOPPED:
                os.write(child_state_w, b"T")
            elif info.si_code == os.CLD_CONTINUED:
                os.write(child_state_w, b"C")

        signal.signal(signal.SIGCHLD, _shepherd_on_sigchld)

        # Blocks until the child actually terminates; a caught SIGCHLD
        # for a mere stop/continue interrupts it, but os.waitpid retries
        # automatically on EINTR (PEP 475), so this only ever returns once
        # for real.
        _, status = os.waitpid(child_pid, 0)
        os.close(child_state_w)
        # Exit the same way the child did, so wrapty's own wait on the
        # shepherd (see the very end of this function) still reports the
        # child's real exit condition.
        if os.WIFSIGNALED(status):
            # No signal.signal() reset needed first -- this process never
            # installed a handler for anything but SIGCHLD, so every other
            # signal, including this one, is already at its OS default.
            # (SIGKILL/SIGSTOP couldn't be reset even if it were needed --
            # the kernel refuses to let anyone touch their disposition.)
            sig = os.WTERMSIG(status)
            try:
                os.kill(os.getpid(), sig)
            except OSError:
                pass
            os._exit(128 + sig)  # in case that signal didn't kill us
        os._exit(os.WEXITSTATUS(status))

    os.close(write_child_pid)
    os.close(child_state_w)
    os.close(slave_fd)
    pid = shepherd_pid  # waited on at the very end, for the final exit code
    child_pid = int(os.read(read_child_pid, 32))
    os.close(read_child_pid)

    runtime_dir = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "wrapty")
    os.makedirs(runtime_dir, exist_ok=True)
    sock_path = os.path.join(runtime_dir, f"{wapty_id}.sock")

    # Redirect diagnostics off stderr from here on: the child is about to own
    # the terminal. The log sits beside the socket, so it goes away with the
    # runtime directory and is easy to find from the session id.
    global _log_path
    _log_path = os.path.join(runtime_dir, f"{wapty_id}.log")

    # os.write on a non-blocking fd can do a *partial* write -- accept fewer
    # bytes than given and return that count, with no exception at all -- so
    # a single fire-and-forget os.write silently drops the remainder for any
    # burst larger than the pty's write buffer (1024 bytes on macOS). A long
    # /compact instructions string is exactly the kind of burst that hits
    # this. Buffering what didn't fit and flushing it once the fd is
    # writable again is required for correctness, not just an optimization.
    _master_write_buffer = bytearray()
    _master_writer_registered = [False]

    def _flush_master_buffer():
        try:
            n = os.write(master_fd, _master_write_buffer)
        except BlockingIOError:
            return
        except OSError:
            _master_write_buffer.clear()
        else:
            del _master_write_buffer[:n]
        if not _master_write_buffer and _master_writer_registered[0]:
            loop.remove_writer(master_fd)
            _master_writer_registered[0] = False

    def write_master(data):
        _master_write_buffer.extend(data)
        _flush_master_buffer()
        if _master_write_buffer and not _master_writer_registered[0]:
            loop.add_writer(master_fd, _flush_master_buffer)
            _master_writer_registered[0] = True

    dispatcher = Dispatcher()
    latest_stats = {}
    # allow_stop: this Stop is permitted rather than nudged, cleared once used.
    # It is deliberately not called need_user, because needing the user is only
    # one of the reasons to set it -- compact() sets it too, and a compaction
    # has nothing to do with wanting the human. What the flag actually means is
    # "let the turn end this once".
    #
    # That splits stops into two kinds, and `resume` is what tells them apart:
    #
    #   permanent  need_user(), resume None -- the agent is done or blocked,
    #              and the turn ending is the point.
    #   temporary  resume set -- the turn has to end for something else to
    #              happen (queued input only submits when the session is idle,
    #              not mid-turn), and the agent is typed back to afterwards so
    #              the work continues. Nobody has to notice and poke it.
    #
    # pending_compact is the temporary case with a condition worth waiting on:
    # it polls for usage to actually drop before resuming. Everything else just
    # settles and resumes.
    #
    # monitors is the same shape again, over a longer span. wrapty-monitor
    # holds an inbox open for the session, and `listen --permit-stop` records
    # it here: the agent's next move depends on a message somebody else has
    # not sent yet, so stopping is right and the nudge would only push it into
    # inventing work. Unlike the two above, which permit exactly one stop,
    # this permits every stop until the listener exits.
    #
    # That is also why --permit-stop is not the default. A listener lives as
    # long as the session, so registering one unasked would silence the nudge
    # for the whole session.
    nudge_state = {
        "allow_stop": False,
        "resume": None,
        "stop_count": 0,
        "cooldowns": {},
        "pending_compact": None,
        "monitors": {},
        "task": None,
    }
    async def _type_and_submit(text_bytes, press_enter):
        """Delivers text_bytes a few bytes at a time with a short, jittered
        delay between chunks, rather than one instant burst -- see
        TYPE_CHUNK_SIZE above. Enter, if requested, follows after its own
        jittered delay, same reasoning as ENTER_DELAY."""
        for i in range(0, len(text_bytes), TYPE_CHUNK_SIZE):
            write_master(text_bytes[i : i + TYPE_CHUNK_SIZE])
            await asyncio.sleep(_jittered(TYPE_CHUNK_DELAY, TYPE_CHUNK_JITTER))
        if press_enter:
            await asyncio.sleep(_jittered(ENTER_DELAY, ENTER_DELAY_JITTER))
            write_master(b"\r")

    @dispatcher.add_method
    async def send(text, press_enter=False, resume=None):
        # Awaited directly (see _dispatch) rather than farmed out to a
        # detached task, so the RPC call -- and the MCP tool call on top of
        # it -- doesn't return until the text has actually been typed, not
        # merely scheduled. A caller that gets "ok" back knows the text is
        # in, not that it will be shortly.
        #
        # Typed is not the same as run, though. The session only submits
        # queued input once it is idle, so text an agent sends to its own box
        # mid-turn sits there until the turn ends -- and if the Stop hook
        # keeps nudging it onward, that never happens and the text is silently
        # stranded. `resume` is the way out: it permits the next Stop and says
        # what to type once the queued input has gone through, so the turn
        # ends, the command runs, and the agent is brought back.
        await _type_and_submit(text.encode(), press_enter)
        if resume is not None:
            nudge_state["allow_stop"] = True
            nudge_state["resume"] = resume
            nudge_state["stop_count"] = 0
            return "ok: stop this turn now, it will be typed back to you after"
        return "ok"

    @dispatcher.add_method
    def stats(data):
        latest_stats.clear()
        latest_stats.update(data)
        return "ok"

    @dispatcher.add_method
    def get_stats():
        return latest_stats

    @dispatcher.add_method
    def need_user():
        # The permanent kind of stop: no resume, so nothing types the agent
        # back afterwards. That is the whole point -- it is now the human's
        # turn.
        #
        # The agent earns this call two ways: the work is done, or a decision
        # only the human can make blocks it. A summary earns nothing. The
        # nudge exists because agents stop to report progress and wait, and
        # every one of those stops is work the agent could have finished.
        nudge_state["allow_stop"] = True
        nudge_state["resume"] = None
        nudge_state["stop_count"] = 0
        return "ok"

    @dispatcher.add_method
    def on_stop():
        """Called once per Stop event. Returns whether the Stop hook should
        nudge the agent, and clears/advances the stop_count accordingly.

        If a compact() call is pending, the turn ending now is exactly what
        it was waiting for: the wrapped session's input box only treats
        injected keystrokes as a real command submission when it's actually
        idle, not mid-turn, so the "/compact...\r" sequence couldn't be sent
        any earlier than this. Hand it off to a background task rather than
        running it here, since this RPC call needs to return promptly."""
        pending = nudge_state["pending_compact"]
        if pending is not None:
            nudge_state["pending_compact"] = None
            nudge_state["allow_stop"] = False
            nudge_state["resume"] = None
            nudge_state["stop_count"] = 0
            nudge_state["task"] = loop.create_task(
                _run_pending_compact(pending["instructions"], pending["used_pct"])
            )
            return {"nudge": False}
        # A temporary stop: whatever was queued gets its turn boundary, then
        # the agent is typed back to. Same hand-off to a background task, and
        # for the same reason.
        if nudge_state["resume"] is not None:
            resume = nudge_state["resume"]
            nudge_state["resume"] = None
            nudge_state["allow_stop"] = False
            nudge_state["stop_count"] = 0
            nudge_state["task"] = loop.create_task(_run_pending_resume(resume))
            return {"nudge": False}
        # Checked before allow_stop so it is not consumed: a monitor permits
        # every stop until it reports, not just the next one.
        if nudge_state["monitors"]:
            nudge_state["stop_count"] = 0
            return {"nudge": False}
        if nudge_state["allow_stop"]:
            nudge_state["allow_stop"] = False
            nudge_state["stop_count"] = 0
            return {"nudge": False}
        nudge_state["stop_count"] += 1
        return {"nudge": True, "count": nudge_state["stop_count"]}

    @dispatcher.add_method
    def monitor_register(label, until, pid=None, timeout=None):
        """Record a running wrapty-monitor. See nudge_state above for why an
        outstanding monitor suppresses the stop nudge for its whole life."""
        nudge_state["monitors"][label] = {
            "until": until,
            "pid": pid,
            "timeout": timeout,
            "started": loop.time(),
        }
        nudge_state["stop_count"] = 0
        return "ok"

    @dispatcher.add_method
    def monitor_done(label):
        nudge_state["monitors"].pop(label, None)
        return "ok"

    @dispatcher.add_method
    def monitor_list():
        now = loop.time()
        return {
            label: dict(info, waiting_seconds=round(now - info["started"], 1))
            for label, info in nudge_state["monitors"].items()
        }

    @dispatcher.add_method
    def check_cooldown(name, seconds):
        """True at most once per `seconds`, per `name`. Records the call as
        the last fire only when it returns True, so callers that decide not
        to act on a True result would wrongly reset the cooldown -- always
        act when this returns True."""
        now = loop.time()
        last = nudge_state["cooldowns"].get(name, float("-inf"))
        if now - last < seconds:
            return False
        nudge_state["cooldowns"][name] = now
        return True

    async def _run_pending_resume(text):
        """Runs after a temporary stop (see on_stop()). Whatever the agent
        queued has submitted by now -- that is what ending the turn was for --
        so this only has to wait for the session to be idle again and then
        type the agent back to.

        There is no equivalent of the compaction check below, because there is
        nothing general to poll: a slash command reports success in the
        transcript, not in the statusline. So this settles and resumes, and an
        agent that needs proof its command took effect should check for it
        after being resumed rather than assume it."""
        await asyncio.sleep(RESUME_SETTLE_DELAY)
        await _type_and_submit(text.encode(), press_enter=True)

    async def _run_pending_compact(instructions, used_pct_before):
        """Runs after the agent's turn has genuinely ended (see on_stop()).
        Types /compact, waits for the context usage the statusline reports
        to actually drop (proof the compaction ran, not just that it was
        typed), then resumes the agent with a plain continue prompt -- a
        real top-level input, since it's typed the same way as everything
        else here."""
        await asyncio.sleep(COMPACT_SETTLE_DELAY)
        text = f"/compact {instructions}" if instructions else "/compact"
        await _type_and_submit(text.encode(), press_enter=True)

        waited = 0.0
        while waited < COMPACT_MAX_WAIT:
            await asyncio.sleep(COMPACT_POLL_INTERVAL)
            waited += COMPACT_POLL_INTERVAL
            now_pct = latest_stats.get("context_window", {}).get("used_percentage")
            if used_pct_before is None or (now_pct is not None and now_pct < used_pct_before - 1):
                break

        await _type_and_submit(CONTINUE_TEXT.encode(), press_enter=True)

    @dispatcher.add_method
    def compact(instructions=""):
        """Schedules a compaction rather than running it immediately -- see
        on_stop() for why it has to wait for the turn to actually end."""
        used_pct = latest_stats.get("context_window", {}).get("used_percentage")
        if used_pct is not None and used_pct < MIN_COMPACT_PCT:
            raise JSONRPCDispatchException(
                code=-32000,
                message=(
                    f"Refusing to compact: context usage is {used_pct:.0f}%, "
                    f"below the configured minimum of {MIN_COMPACT_PCT:.0f}%."
                ),
            )
        nudge_state["pending_compact"] = {"instructions": instructions, "used_pct": used_pct}
        nudge_state["allow_stop"] = True
        nudge_state["stop_count"] = 0
        return "scheduled: stop this turn now, compaction runs once it ends"

    server = await asyncio.start_unix_server(
        lambda r, w: _handle_client(r, w, dispatcher), path=sock_path
    )

    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_on_loop_exception)
    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    os.set_blocking(master_fd, False)
    # Deliberately not making stdin_fd non-blocking: on a real terminal, fd 0
    # and fd 1 are dups of the same open file description, so O_NONBLOCK on
    # one silently applies to the other too, breaking blocking writes to
    # stdout_fd. We're the sole reader of stdin_fd, so a plain blocking read
    # after add_reader fires won't actually block.

    done = loop.create_future()

    def on_master_readable():
        try:
            data = os.read(master_fd, 4096)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            if not done.done():
                done.set_result(None)
            return
        os.write(stdout_fd, data)

    # Set the instant the SIGCHLD handler below observes the child having
    # genuinely stopped (see the shepherd comment above for why that now
    # actually happens), cleared once we've woken it back up. Lets both
    # _suspend_self and the handler agree on whether the child still needs
    # a real SIGCONT, versus just a redraw nudge.
    child_stopped = [False]

    def _suspend_self():
        """Stop this process the way a real terminal would on the suspend
        keystroke: reset the modes the wrapped TUI may have left on (see
        TERMINAL_RESET), restore cooked mode so the shell gets a sane
        terminal back, actually stop (so job control -- fg/bg -- works),
        then re-enter raw mode once resumed. Called both when THIS process
        catches the suspend keystroke directly, and when
        on_child_state_readable below notices the child stopped itself --
        in the latter case the terminal reset still applies (the child's
        TUI never got a chance to leave its own modes cleanly either
        way)."""
        if old_attrs is not None:
            os.write(stdout_fd, TERMINAL_RESET)
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)
        os.kill(os.getpid(), signal.SIGTSTP)
        # execution resumes here once the shell sends SIGCONT (e.g. `fg`)
        if old_attrs is not None:
            tty.setraw(sys.stdin)
            _sync_winsize(stdin_fd, master_fd)
            if child_stopped[0]:
                # The child stopped for real (see the shepherd comment
                # above) -- only an actual SIGCONT resumes a stopped
                # process, so it needs one of its own; our own SIGCONT
                # doesn't reach it, they're different processes.
                #
                # killpg, not kill: the child's own self-suspend handling
                # (whatever mechanism it uses -- observed empirically, not
                # from its source) stops its own process GROUP, not just
                # its own pid, so anything it has spawned that inherited
                # that group (e.g. an MCP server subprocess it launched)
                # stops right along with it. A plain kill(child_pid,
                # SIGCONT) only wakes the child itself, leaving those
                # siblings stopped forever with nothing left to resume
                # them -- confirmed live: wrapty-mcp, spawned by Claude
                # Code and sharing its pgid, stayed in T state
                # indefinitely after a real ^Z/fg cycle woke Claude Code
                # itself back up. child_pid is its own process group
                # leader (see os.setpgid(child_pid, child_pid) in the
                # shepherd above), so killpg(child_pid, ...) reaches
                # exactly that group.
                child_stopped[0] = False
                try:
                    os.killpg(child_pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
            else:
                # The child never knew any of this happened -- it wasn't
                # suspended, and has no idea the terminal was reset out
                # from under it. SIGWINCH is the same nudge a real resize
                # sends; most full-screen TUIs treat it as "redraw
                # everything", which re-asserts whatever modes (alt
                # screen, cursor, mouse) the child actually needs. Sent to
                # the whole group for the same reason as the SIGCONT
                # above -- a real resize reaches every process in the
                # foreground group, not just the one leading it.
                try:
                    os.killpg(child_pid, signal.SIGWINCH)
                except ProcessLookupError:
                    pass

    def on_child_state_readable():
        """Notices the child stopping itself -- its own native suspend
        keystroke handling self-sends SIGTSTP, which the shepherd process
        (see the top of this function) turns into a real, observable stop
        instead of a silent no-op, and forwards here over child_state_r
        since only the shepherd, as the child's actual parent, can wait()
        on it."""
        try:
            data = os.read(child_state_r, 4096)
        except BlockingIOError:
            return
        if not data:
            loop.remove_reader(child_state_r)
            return
        # Only the most recent byte matters -- a stop and continue since
        # the last time this ran collapse to whatever state it's in now.
        if data[-1:] == b"T":
            if old_attrs is not None and not child_stopped[0]:
                child_stopped[0] = True
                _suspend_self()
        elif data[-1:] == b"C":
            child_stopped[0] = False

    def on_stdin_readable():
        try:
            data = os.read(stdin_fd, 4096)
        except BlockingIOError:
            return
        if not data:
            loop.remove_reader(stdin_fd)
            return
        if suspend_byte and suspend_byte in data:
            before, _, after = data.partition(suspend_byte)
            if before:
                write_master(before)
            _suspend_self()
            if after:
                write_master(after)
            return
        write_master(data)

    loop.add_reader(master_fd, on_master_readable)
    try:
        loop.add_reader(stdin_fd, on_stdin_readable)
    except OSError:
        pass  # e.g. stdin is /dev/null: kqueue refuses to poll it, nothing to forward anyway
    os.set_blocking(child_state_r, False)
    loop.add_reader(child_state_r, on_child_state_readable)

    old_attrs = None
    suspend_byte = None
    if sys.stdin.isatty():
        old_attrs = termios.tcgetattr(sys.stdin)
        suspend_byte = old_attrs[6][termios.VSUSP] or None
        tty.setraw(sys.stdin)
        _sync_winsize(stdin_fd, master_fd)
        loop.add_signal_handler(signal.SIGWINCH, _sync_winsize, stdin_fd, master_fd)

        def _on_sigcont():
            # Covers a SIGTSTP that arrived some way other than the suspend
            # keystroke (e.g. `kill -TSTP`) and so skipped _suspend_self's
            # own resume handling -- redundant but harmless otherwise.
            tty.setraw(sys.stdin)
            _sync_winsize(stdin_fd, master_fd)

        loop.add_signal_handler(signal.SIGCONT, _on_sigcont)

    def _on_terminate():
        """The terminal going away (SIGHUP -- e.g. the SSH session
        dropping) or an ordinary `kill` (SIGTERM) would otherwise skip the
        `finally` below entirely: the real terminal is left in whatever
        raw/alt-screen state the TUI last set (moot for SIGHUP, the
        terminal's already gone, but not for a SIGTERM from something
        else), and the shepherd + child are orphaned with nothing left to
        reap or terminate them.

        SIGCONT first: a signal sent to a currently-stopped process (see
        child_stopped above) stays merely pending, not delivered, until
        it's resumed -- without it, a child stopped at the moment of
        teardown would never actually see the SIGTERM that follows.

        Best-effort, not a guaranteed-bounded kill: a child that ignores
        SIGTERM is not escalated to SIGKILL. Doing that correctly needs the
        final os.waitpid below to stop blocking the event loop, which is
        more machinery than a child ignoring SIGTERM warrants here."""
        if old_attrs is not None:
            try:
                os.write(stdout_fd, TERMINAL_RESET)
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)
            except OSError:
                pass
        try:
            os.killpg(child_pid, signal.SIGCONT)
            os.killpg(child_pid, signal.SIGTERM)
        except OSError:
            pass
        if not done.done():
            done.set_result(None)

    loop.add_signal_handler(signal.SIGTERM, _on_terminate)
    loop.add_signal_handler(signal.SIGHUP, _on_terminate)

    try:
        await done
    finally:
        loop.remove_reader(master_fd)
        if _master_writer_registered[0]:
            loop.remove_writer(master_fd)
        try:
            loop.remove_reader(stdin_fd)
        except (ValueError, OSError):
            pass
        try:
            loop.remove_reader(child_state_r)
        except (ValueError, OSError):
            pass
        server.close()
        await server.wait_closed()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        loop.remove_signal_handler(signal.SIGTERM)
        loop.remove_signal_handler(signal.SIGHUP)
        if old_attrs is not None:
            loop.remove_signal_handler(signal.SIGWINCH)
            loop.remove_signal_handler(signal.SIGCONT)
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)

    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: wrapty CMD [ARGS...]", file=sys.stderr)
        sys.exit(1)
    sys.exit(asyncio.run(_run(argv)))


if __name__ == "__main__":
    main()
