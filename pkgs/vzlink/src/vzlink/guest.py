"""The builder guest's readiness agent: `vzlink-guest`.

Answers one question over vsock: is nix-daemon serving yet? The host
supervisor asks this after the SSH banner, so "the VM answers" and "the
builder serves" stop being one indistinguishable wait.

One JSON line per connection, then close. Checks are cheap filesystem
probes -- nothing here may block a boot, and nothing in the boot waits on
this service. Best effort by construction.
"""

from __future__ import annotations

import argparse
import logging
import os
import socket
import sys
from typing import Any, Final

import anyio
import anyio.abc

from vzlink.protocol import STREAM_ERRORS, Op, ok, send_message

logger: Final = logging.getLogger("vzlink.guest")

VSOCK_PORT: Final = 11123


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Command line. Paths are flags so tests can point them at temp dirs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsock-port", type=int, default=VSOCK_PORT)
    parser.add_argument("--daemon-socket", default="/nix/var/nix/daemon-socket/socket")
    parser.add_argument("--store-dir", default="/nix/store")
    return parser.parse_args(argv)


async def readiness(*, daemon_socket: str, store_dir: str) -> tuple[bool, list[str]]:
    """Whether the builder serves. Reasons name every failed check, so the
    host's wait error says what was missing instead of just timing out."""
    reasons: list[str] = []
    if not await anyio.Path(daemon_socket).exists():
        reasons.append("daemon-socket-missing")
    if not await anyio.Path(store_dir).is_dir():
        reasons.append("store-not-mounted")
    return (not reasons, reasons)


async def info() -> dict[str, Any]:
    """Load for the host's log line, never gating."""
    try:
        return {"loadavg": (await anyio.Path("/proc/loadavg").read_text()).split()[0]}
    except OSError:
        return {}


SD_LISTEN_FDS_START: Final = 3


def systemd_listener() -> socket.socket | None:
    """The listening socket systemd passed, if it passed one (sd_listen_fds).
    A socket unit listens from sockets.target on, well before this process
    has started, so a probe that arrives early waits instead of missing."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        return None
    if int(os.environ.get("LISTEN_FDS", "0")) < 1:
        return None
    return socket.socket(fileno=SD_LISTEN_FDS_START)


def vsock_listener(port: int) -> socket.socket:
    """A bound, listening vsock socket. Raises RuntimeError where vsock does
    not exist, which is every platform but the guest."""
    family = getattr(socket, "AF_VSOCK", None)
    cid_any = getattr(socket, "VMADDR_CID_ANY", None)
    if family is None or cid_any is None:
        raise RuntimeError("vsock sockets are not available on this platform")
    listener = socket.socket(family, socket.SOCK_STREAM)
    listener.bind((cid_any, port))
    listener.listen(128)
    return listener


async def handle(stream: anyio.abc.SocketStream, *, daemon_socket: str, store_dir: str) -> None:
    """Answer one readiness probe, then close."""
    async with stream:
        try:
            ready, reasons = await readiness(daemon_socket=daemon_socket, store_dir=store_dir)
            await send_message(stream, ok(Op.READINESS, ready=ready, reasons=reasons, **await info()))
        except STREAM_ERRORS as exc:
            logger.warning("probe failed: %r", exc)


async def _accept(listener: socket.socket) -> anyio.abc.SocketStream:
    """Accept one connection on a non-blocking listener of any family.

    Not anyio's SocketListener: its accept sets TCP_NODELAY, which a vsock
    socket rejects.
    """
    while True:
        await anyio.wait_readable(listener)
        try:
            conn, _ = listener.accept()
        except BlockingIOError:
            continue
        return await anyio.abc.SocketStream.from_socket(conn)


async def serve(listener: socket.socket, *, daemon_socket: str, store_dir: str) -> None:
    """Accept probes until cancelled, then close the listener. Takes any
    listening stream socket, so tests serve TCP on loopback instead of vsock."""
    listener.setblocking(False)
    try:
        async with anyio.create_task_group() as task_group:
            while True:
                stream = await _accept(listener)
                task_group.start_soon(_handle_one, stream, daemon_socket, store_dir)
    finally:
        listener.close()


async def _handle_one(stream: anyio.abc.SocketStream, daemon_socket: str, store_dir: str) -> None:
    await handle(stream, daemon_socket=daemon_socket, store_dir=store_dir)


async def _amain(args: argparse.Namespace) -> None:
    listener = systemd_listener()
    origin = "systemd"
    if listener is None:
        listener = vsock_listener(args.vsock_port)
        origin = f"vsock:{args.vsock_port}"
    logger.info("answering readiness on %s (daemon socket %s)", origin, args.daemon_socket)
    await serve(listener, daemon_socket=args.daemon_socket, store_dir=args.store_dir)


def main(argv: list[str] | None = None) -> int:
    """Console script entry point. Runs until killed; systemd restarts it."""
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03d %(name)s %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S",
        stream=sys.stderr,
    )
    anyio.run(_amain, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
