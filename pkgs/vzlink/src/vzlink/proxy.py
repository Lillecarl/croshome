"""One proxied connection into the builder guest: `vzlink-proxy`.

launchd starts one of these per accepted connection, with the accepted socket
on stdin/stdout. It asks the supervisor to bring the VM up, registers itself,
forwards bytes between the client and the guest's sshd, then unregisters.

Every stage is logged with the connection id, so a wedged build leaves a
trail: when it arrived, how long the boot took, how many bytes moved, and how
the connection ended.
"""

from __future__ import annotations

import argparse
import logging
import shlex
import subprocess
import sys
import time
from typing import TYPE_CHECKING, Any, Final

import anyio
import anyio.abc

from vzlink.forward import Activity, EndedBy, forward
from vzlink.protocol import (
    STREAM_ERRORS,
    ControlError,
    Op,
    ProtocolError,
    check_response,
    new_conn_id,
    read_message,
    send_message,
)

if TYPE_CHECKING:
    from vzlink.forward import ForwardStats

logger: Final = logging.getLogger("vzlink.proxy")

SUPERVISOR_POLL: Final = 0.25
RPC_SLOP: Final = 5.0
KICKSTART_TIMEOUT: Final = 30.0
CONNECT_TIMEOUT: Final = 5.0
STALL_WARN_AFTER: Final = 300.0
STALL_CHECK_EVERY: Final = 60.0

RPC_ERRORS: Final = (ControlError, ProtocolError, TimeoutError, *STREAM_ERRORS)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Command line. The nix module passes every value; defaults mirror it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-sock", default="/var/lib/vz-builder/vzlink-control.sock")
    parser.add_argument("--internal-port", type=int, default=31123)
    parser.add_argument("--boot-timeout", type=float, default=90.0)
    parser.add_argument("--daemon-label", default="org.nixos.vz-builder-vm")
    parser.add_argument(
        "--kickstart-cmd",
        default=None,
        help="Shell words to start the VM, instead of launchctl kickstart. Tests pass `true`.",
    )
    return parser.parse_args(argv)


async def _kickstart(argv: list[str]) -> int:
    """Start the VM daemon. Failure is advisory: the supervisor may already
    be up, and the wait after this is what decides."""
    try:
        with anyio.fail_after(KICKSTART_TIMEOUT):
            # Never inherit: fd 0 and fd 1 are the client's SSH connection.
            proc = await anyio.run_process(
                argv,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except (OSError, TimeoutError) as exc:
        logger.warning("kickstart failed: %r", exc)
        return 127
    return proc.returncode


async def _wait_for_supervisor(path: str, deadline: float) -> None:
    """Wait until the supervisor's control socket accepts. It appears when
    the supervisor binds it, seconds after kickstart."""
    while True:
        try:
            stream = await anyio.connect_unix(path)
        except OSError:
            pass
        else:
            await stream.aclose()
            return
        if time.monotonic() >= deadline:
            raise ControlError(f"supervisor never appeared at {path}")
        await anyio.sleep(SUPERVISOR_POLL)


async def _rpc(path: str, op: Op, conn_id: str, timeout: float) -> dict[str, Any]:
    """One RPC: fresh connection, one message each way, then close."""
    with anyio.fail_after(timeout):
        async with await anyio.connect_unix(path) as stream:
            await send_message(stream, {"op": op.value, "id": conn_id})
            return check_response(await read_message(stream), op)


async def _stall_monitor(activity: Activity, log: logging.Logger) -> None:
    """Warn when an open connection moves nothing for a long time. The
    guest's sshd sends keepalives on idle sessions, so silence past the
    threshold is worth a log line, not a verdict."""
    warned_at = 0.0
    while True:
        await anyio.sleep(STALL_CHECK_EVERY)
        quiet_for = time.monotonic() - activity.last
        if quiet_for >= STALL_WARN_AFTER and warned_at < activity.last:
            warned_at = time.monotonic()
            log.warning("no traffic for %.0fs on an open connection", quiet_for)


async def _forward_with_monitor(
    client: anyio.abc.SocketStream,
    upstream: anyio.abc.SocketStream,
    log: logging.Logger,
) -> ForwardStats:
    activity = Activity()
    async with anyio.create_task_group() as task_group:
        task_group.start_soon(_stall_monitor, activity, log)
        stats = await forward(client, upstream, activity=activity)
        task_group.cancel_scope.cancel()
    return stats


async def _bring_up(
    args: argparse.Namespace, conn_id: str, log: logging.Logger
) -> anyio.abc.SocketStream:
    """Kickstart, wait for the supervisor, wait for the guest, connect, and
    register. Raises one of RPC_ERRORS or OSError at the stage that failed."""
    start = time.monotonic()
    if args.kickstart_cmd is not None:
        kickstart_argv = shlex.split(args.kickstart_cmd)
    else:
        kickstart_argv = ["/bin/launchctl", "kickstart", f"system/{args.daemon_label}"]
    log.info("kickstart rc=%d", await _kickstart(kickstart_argv))

    deadline = start + args.boot_timeout
    await _wait_for_supervisor(args.control_sock, deadline)
    remaining = max(deadline - time.monotonic(), 1.0)
    info = await _rpc(args.control_sock, Op.ENSURE_UP, conn_id, remaining + RPC_SLOP)
    log.info("guest ready after %.1fs: %s", time.monotonic() - start, info.get("stages", []))

    with anyio.fail_after(CONNECT_TIMEOUT):
        upstream = await anyio.connect_tcp("127.0.0.1", args.internal_port)
    try:
        await _rpc(args.control_sock, Op.REGISTER, conn_id, RPC_SLOP)
    except BaseException:
        await upstream.aclose()
        raise
    return upstream


async def _run_proxy(args: argparse.Namespace) -> int:
    conn_id = new_conn_id()
    start = time.monotonic()
    log = logging.getLogger(f"vzlink.proxy.{conn_id}")

    client = await anyio.abc.SocketStream.from_socket(0)
    try:
        upstream = await _bring_up(args, conn_id, log)
    except (*RPC_ERRORS, OSError) as exc:
        log.error("not forwarding: %r", exc)
        await client.aclose()
        return 1

    try:
        stats = await _forward_with_monitor(client, upstream, log)
    finally:
        with anyio.CancelScope(shield=True):
            try:
                await _rpc(args.control_sock, Op.UNREGISTER, conn_id, RPC_SLOP)
            except RPC_ERRORS as exc:
                log.warning("unregister failed: %r", exc)

    log.info(
        "closed: %s %s up=%d down=%d duration=%.1fs",
        stats.ended_by,
        stats.detail,
        stats.a_to_b,
        stats.b_to_a,
        time.monotonic() - start,
    )
    return 0 if stats.ended_by is EndedBy.EOF else 1


def main(argv: list[str] | None = None) -> int:
    """Console script entry point. Returns the process exit code."""
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03d %(name)s %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S",
        stream=sys.stderr,
    )
    return anyio.run(_run_proxy, args)


if __name__ == "__main__":
    sys.exit(main())
