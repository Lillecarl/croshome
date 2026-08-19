"""An inbox for a Claude Code session: anything local can post, the session
gets a notification.

Claude Code's Monitor tool runs a command and turns every line the command
writes to stdout into a notification in the conversation. That is the whole
mechanism this builds on. `listen` is a command that writes a line whenever
somebody posts one, so the agent runs it under Monitor and then hears from
the outside world for as long as the session lives:

    Monitor(command="wrapty-monitor listen", persistent=true,
            description="messages posted to this session")

    wrapty-monitor post 'the deploy finished, log is at /tmp/deploy.log'

The poster can be anything on this machine: another terminal, a git hook, a
cron job, a CI script, another agent. It needs no cooperation from the
session beyond knowing which one to post to.

Why not type into the session's terminal instead? Because a person may be
typing at the same moment, and the two interleave into one garbled line.
Notifications go through Claude Code's own channel and cannot collide with a
keyboard. That is not a detail -- it is the reason this shape exists.

The session is addressed by its wrapty id, so two sessions on one machine
never share an inbox. `list` shows what is live, for a poster that does not
already know the id.

Posting is local-only by design: the inbox is a unix socket under
$XDG_RUNTIME_DIR, so who may post is a filesystem question and nothing
listens on the network.
"""

import argparse
import asyncio
import os
import socket
import sys

from wrapty_client import call, runtime_dir


def _inbox_dir() -> str:
    return os.path.join(runtime_dir(), "inbox")


def _socket_path(session_id: str) -> str:
    return os.path.join(_inbox_dir(), f"{session_id}.sock")


def _session_id() -> str:
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        sys.exit("not running under wrapty (WAPTY_ID is not set)")
    return wapty_id


def _rpc(method, params=None):
    return asyncio.run(call(_session_id(), method, params))


def _is_live(path: str) -> bool:
    """Whether something is accepting connections on this socket.

    A socket file outlives the process that made it, so its presence proves
    nothing. Connecting is the only honest test.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(1)
        sock.connect(path)
        return True
    except OSError:
        return False
    finally:
        sock.close()


async def _serve(path: str, once: bool):
    stop = asyncio.Event()

    async def handle(reader, writer):
        # Read to EOF rather than one line: a posted message may be several
        # lines, and Claude Code batches stdout written within 200ms into a
        # single notification, so it arrives whole.
        data = await reader.read()
        writer.close()
        text = data.decode("utf-8", "replace").rstrip("\n")
        if text:
            print(text, flush=True)
            if once:
                stop.set()

    server = await asyncio.start_unix_server(handle, path=path)
    os.chmod(path, 0o600)
    try:
        if once:
            await stop.wait()
        else:
            await asyncio.Event().wait()
    finally:
        server.close()


def _listen(args):
    session_id = _session_id()
    path = _socket_path(session_id)
    os.makedirs(_inbox_dir(), exist_ok=True)

    if os.path.exists(path):
        if _is_live(path):
            sys.exit(f"already listening for this session at {path}")
        os.unlink(path)  # left behind by a listener that is gone

    if args.permit_stop:
        # Off by default on purpose. A listener runs for the whole session,
        # so registering one would suppress the stop nudge permanently --
        # which is the opposite of what the nudge is for. Pass this only when
        # the session's next move genuinely depends on a posted message.
        _rpc("monitor_register", {
            "label": f"inbox:{session_id}",
            "until": "a message posted to this session's inbox",
            "pid": os.getpid(),
        })

    print(f"inbox open. Post to it with: wrapty-monitor post --to {session_id} 'text'",
          flush=True)
    try:
        asyncio.run(_serve(path, args.once))
    except KeyboardInterrupt:
        pass
    finally:
        if args.permit_stop:
            try:
                _rpc("monitor_done", {"label": f"inbox:{session_id}"})
            except Exception:  # noqa: BLE001 -- the session may already be gone
                pass
        try:
            os.unlink(path)
        except OSError:
            pass


def _post(args):
    session_id = args.to or os.environ.get("WAPTY_ID")
    if not session_id:
        sys.exit(
            "no session to post to: pass --to ID, or set WAPTY_ID. "
            "`wrapty-monitor list` shows the sessions that are listening."
        )

    text = " ".join(args.text) if args.text else sys.stdin.read()
    text = text.rstrip("\n")
    if not text:
        sys.exit("refusing to post an empty message")

    path = _socket_path(session_id)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(5)
        sock.connect(path)
        sock.sendall(text.encode())
        # Half-close, so the listener's read-to-EOF returns. Without this it
        # waits for a close that only comes when this process exits.
        sock.shutdown(socket.SHUT_WR)
    except FileNotFoundError:
        sys.exit(f"nothing is listening for session {session_id}")
    except ConnectionRefusedError:
        sys.exit(f"session {session_id} left a stale socket behind; it is not listening")
    finally:
        sock.close()
    print("posted")


def _list(_args):
    directory = _inbox_dir()
    if not os.path.isdir(directory):
        print("no sessions are listening")
        return
    live = [
        name[: -len(".sock")]
        for name in sorted(os.listdir(directory))
        if name.endswith(".sock") and _is_live(os.path.join(directory, name))
    ]
    if not live:
        print("no sessions are listening")
        return
    here = os.environ.get("WAPTY_ID")
    for session_id in live:
        mine = "  (this session)" if session_id == here else ""
        print(f"{session_id}{mine}")


def main():
    parser = argparse.ArgumentParser(
        prog="wrapty-monitor",
        description="An inbox for a Claude Code session. Run `listen` under "
                    "Claude Code's Monitor tool; anything local can then post "
                    "a message and the session is notified.",
    )
    sub = parser.add_subparsers(dest="command")

    listen = sub.add_parser(
        "listen",
        help="print every posted message, one event per message; run under Monitor",
    )
    listen.add_argument("--once", action="store_true",
                        help="exit after the first message, ending the watch")
    listen.add_argument("--permit-stop", action="store_true",
                        help="suppress the stop nudge while listening. Off by "
                             "default: a listener lives as long as the session, "
                             "so this silences the nudge for that whole time")
    listen.set_defaults(func=_listen)

    post = sub.add_parser("post", help="send a message to a listening session")
    post.add_argument("text", nargs="*",
                      help="the message; read from stdin when absent")
    post.add_argument("--to", metavar="ID",
                      help="session to post to (default: this session's WAPTY_ID)")
    post.set_defaults(func=_post)

    sub.add_parser("list", help="show the sessions that are listening") \
       .set_defaults(func=_list)

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        return 2

    try:
        args.func(args)
    except FileNotFoundError:
        sys.exit("wrapty is not listening for this session; is it still running?")
    except RuntimeError as exc:
        # A wrapty older than this answers every monitor_* call that way.
        # Worth naming, because a bare `wrapty-monitor` inside a session is
        # itself the old build: wrapty's wrapper puts its own store bin/ at
        # the front of PATH. So a rebuild changes neither side until the
        # session restarts. See home/wrapty.nix.
        if "Method not found" in str(exc):
            sys.exit(
                "this session's wrapty predates --permit-stop. A rebuild does "
                "not reach a running session, so restart the session to pick "
                "it up, or drop the flag."
            )
        sys.exit(f"wrapty refused the call: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
