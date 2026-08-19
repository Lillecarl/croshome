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
    async for line in reader:
        response = await _dispatch(line.decode(), dispatcher)
        writer.write(response.json.encode() + b"\n")
        await writer.drain()
    writer.close()


async def _run(argv):
    wapty_id = secrets.token_hex(4)

    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ["WAPTY_ID"] = wapty_id
        os.execvp(argv[0], argv)

    runtime_dir = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "wrapty")
    os.makedirs(runtime_dir, exist_ok=True)
    sock_path = os.path.join(runtime_dir, f"{wapty_id}.sock")

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

    def _suspend_self():
        """Stop this process the way a real terminal would on the suspend
        keystroke: restore cooked mode so the shell gets a sane terminal
        back, actually stop (so job control -- fg/bg -- works), then
        re-enter raw mode once resumed. The wrapped child lives in its own
        session (pty.fork() called setsid() for it) so it's unaffected and
        keeps running while we're stopped -- that's the whole point."""
        if old_attrs is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)
        os.kill(os.getpid(), signal.SIGTSTP)
        # execution resumes here once the shell sends SIGCONT (e.g. `fg`)
        if old_attrs is not None:
            tty.setraw(sys.stdin)
            _sync_winsize(stdin_fd, master_fd)

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
        server.close()
        await server.wait_closed()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
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
