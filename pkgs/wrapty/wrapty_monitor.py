"""Watch for something outside this session, then type the agent back to.

The problem this solves: an agent often has to wait for work it does not own
-- a CI run, a deploy, a long build in another terminal, a file that some
other process writes. Its options today are both bad. It can block a tool
call and hold the turn open for as long as the wait, or it can poll, which
costs a turn every time and still sleeps between checks.

A monitor is the third option. The agent starts one, ends its turn, and
stops costing anything at all. Some minutes later the condition holds, the
monitor types a message into the session, and the agent picks the work back
up as if it had been waiting attentively.

    wrapty-monitor start \\
        --until 'gh run view --json status -q .status | grep -qx completed' \\
        --wake 'The CI run finished. Read the result and fix what failed.' \\
        --interval 30 --timeout 3600

The predicate is a shell command. Exit 0 means the condition holds. That is
the whole interface, and it is enough for anything a shell can answer.

Two things make this safe to leave running. The monitor registers itself
with wrapty, so the Stop hook stops nudging the agent to keep working while
the wait is legitimate. And it always reports, on its timeout if not on its
condition, so the session is never left silently waiting on something that
already gave up.

The wake text arrives as a fresh prompt with no context around it. Write it
so it stands alone: say what happened and what to do next, not "it's done".
"""

import argparse
import asyncio
import os
import subprocess
import sys
import time

from wrapty_client import call, runtime_dir

# How long to let the session settle before typing into it. Same reasoning as
# wrapty's own resume path: the condition holding says nothing about whether
# the terminal is mid-redraw.
SETTLE_DELAY = float(os.environ.get("WRAPTY_MONITOR_SETTLE_DELAY", "1"))


def _session_id() -> str:
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        sys.exit("not running under wrapty (WAPTY_ID is not set)")
    return wapty_id


def _rpc(method, params=None):
    return asyncio.run(call(_session_id(), method, params))


def _log_path(label):
    return os.path.join(runtime_dir(), f"monitor-{label}.log")


def _wake(label, text):
    """Type into the session. A failure here goes to the monitor's log rather
    than to a terminal: by this point the process is detached and its output
    is redirected, so there is nowhere else for it to land."""
    time.sleep(SETTLE_DELAY)
    try:
        _rpc("send", {"text": text, "press_enter": True})
    except Exception as exc:  # noqa: BLE001 -- nothing above to handle it
        print(f"wrapty-monitor[{label}]: could not wake the session: {exc}",
              file=sys.stderr)


def _detach(label):
    """Double fork, so the monitor outlives the shell that started it.

    An agent starts this from a tool call, and that call's process group goes
    away when the call returns. Without this the monitor would be killed
    moments after being started, which is a failure that looks exactly like a
    condition that never fired.

    stdout and stderr are redirected for a second reason, unrelated to noise:
    a caller reading the tool call's output waits for the pipe to close, and
    the pipe does not close while a detached child still holds the write end.
    Keeping them would hang the very tool call this is supposed to free.
    """
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(devnull)
    os.makedirs(runtime_dir(), exist_ok=True)
    log = os.open(_log_path(label), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.close(log)


def _watch(label, until, interval, timeout, wake, expired):
    deadline = time.monotonic() + timeout if timeout else None
    while True:
        completed = subprocess.run(
            ["sh", "-c", until],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if completed.returncode == 0:
            _wake(label, wake)
            return
        if deadline is not None and time.monotonic() >= deadline:
            _wake(label, expired)
            return
        # Do not overshoot the deadline by a whole interval.
        remaining = interval
        if deadline is not None:
            remaining = min(interval, max(0.0, deadline - time.monotonic()))
        time.sleep(remaining)


def _start(args):
    label = args.label or f"monitor-{os.getpid()}"
    timeout = args.timeout or None

    if timeout is None:
        expired = None
    elif args.expired:
        expired = args.expired
    else:
        expired = (
            f"The monitor '{label}' gave up after {timeout:.0f}s without its "
            f"condition holding. It was waiting for: {args.until}. "
            "Decide whether to wait again, check by hand, or do something else."
        )

    # Registered before forking, for two reasons. An unreachable socket
    # becomes a failed command the agent sees, rather than a silent death in a
    # child it cannot observe. And the registration is what permits the agent
    # to stop, so it has to exist before this command returns -- registering
    # from the child would leave a window where the agent has been told it may
    # stop and the Stop hook does not yet agree.
    _rpc("monitor_register", {
        "label": label,
        "until": args.until,
        "timeout": timeout,
    })

    print(f"monitor '{label}' started; this turn may now end.")
    print(f"  until:    {args.until}")
    print("  interval: {}s{}".format(
        args.interval,
        f", timeout {timeout:.0f}s" if timeout else ", no timeout",
    ))
    print(f"  log:      {_log_path(label)}")
    print("The session is woken when the condition holds. Stop your turn now:")
    print("working on past this point wastes the wait.")
    sys.stdout.flush()

    _detach(label)

    try:
        # Again, now that there is a pid worth recording -- `cancel` needs it.
        _rpc("monitor_register", {
            "label": label,
            "until": args.until,
            "pid": os.getpid(),
            "timeout": timeout,
        })
        _watch(label, args.until, args.interval, timeout, args.wake, expired)
    finally:
        try:
            _rpc("monitor_done", {"label": label})
        except Exception:  # noqa: BLE001 -- the session may already be gone
            pass


def _list(_args):
    monitors = _rpc("monitor_list")
    if not monitors:
        print("no monitors running")
        return
    for label, info in monitors.items():
        print(f"{label}  pid={info.get('pid')}  waiting={info['waiting_seconds']}s")
        print(f"  until: {info['until']}")


def _cancel(args):
    monitors = _rpc("monitor_list")
    info = monitors.get(args.label)
    if info is None:
        sys.exit(f"no monitor called '{args.label}'")
    pid = info.get("pid")
    if pid:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass  # already gone; clearing the registration below is the point
    _rpc("monitor_done", {"label": args.label})
    print(f"cancelled '{args.label}'")


def main():
    parser = argparse.ArgumentParser(
        prog="wrapty-monitor",
        description="Wait for a shell condition, then wake this Claude session.",
    )
    sub = parser.add_subparsers(dest="command")

    start = sub.add_parser("start", help="start a monitor and detach")
    start.add_argument("--until", required=True, metavar="CMD",
                       help="shell command polled until it exits 0")
    start.add_argument("--wake", required=True, metavar="TEXT",
                       help="typed into the session when the condition holds; "
                            "it arrives with no context, so make it stand alone")
    start.add_argument("--interval", type=float, default=30.0, metavar="SEC",
                       help="seconds between checks (default: 30)")
    start.add_argument("--timeout", type=float, default=0.0, metavar="SEC",
                       help="give up after this long (default: no timeout)")
    start.add_argument("--expired", metavar="TEXT",
                       help="typed instead if the timeout is reached")
    start.add_argument("--label", metavar="NAME",
                       help="name for this monitor (default: monitor-<pid>)")
    start.set_defaults(func=_start)

    sub.add_parser("list", help="show the monitors this session has running") \
       .set_defaults(func=_list)

    cancel = sub.add_parser("cancel", help="stop a monitor")
    cancel.add_argument("label")
    cancel.set_defaults(func=_cancel)

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        return 2

    try:
        args.func(args)
    except FileNotFoundError:
        # The id is set but the socket is not there: the wrapping session has
        # gone away, or this is a stale environment inherited from one.
        sys.exit("wrapty is not listening for this session; is it still running?")
    except RuntimeError as exc:
        # A wrapty older than the monitor answers every monitor_* call this
        # way. Worth naming, because the fix is not obvious and the raw
        # message is not either: a rebuild does not reach a session that is
        # already running, so wrapty stays on the binary it started with
        # until the session restarts. See home/wrapty.nix.
        if "Method not found" in str(exc):
            sys.exit(
                "this session's wrapty predates wrapty-monitor. A rebuild "
                "does not reach a running session, so restart the session "
                "to pick it up."
            )
        sys.exit(f"wrapty refused the call: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
