"""The builder VM's supervisor: `vzlink-supervisor`.

runVm execs this after spawning vzvm, so it is vzvm's parent and the process
that outlives the boot. It owns three things:

- readiness: proxies ask `ensure_up` over the control socket, and concurrent
  asks during one boot serialize here instead of each running their own
  poll loop. The answer names the stages and their timings.
- connection tracking: proxies `register` when forwarding starts and
  `unregister` when it ends. An explicit count, not `pgrep -f`.
- idle shutdown: no registered connections and no boot in flight for
  `idle-timeout` stops the VM -- SIGTERM, a bounded wait, then SIGKILL --
  with each step logged.

Exit code is 0 after an idle or signal shutdown, 1 when the VM died first.
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import time
from enum import StrEnum
from typing import Any, Final

import anyio
import anyio.abc

from vzlink.protocol import (
    STREAM_ERRORS,
    Op,
    PeerClosed,
    ProtocolError,
    error,
    ok,
    read_message,
    send_message,
)

logger: Final = logging.getLogger("vzlink.supervisor")

BANNER: Final = b"SSH-"
BANNER_POLL: Final = 0.25
READY_POLL: Final = 0.5
PROBE_TIMEOUT: Final = 5.0
STOP_GRACE: Final = 30.0
KILL_GRACE: Final = 5.0
STOP_POLL: Final = 0.5


class StopReason(StrEnum):
    IDLE = "idle"
    SIGNAL = "signal"
    VM_DIED = "vm-died"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Command line. The nix module passes every value; defaults mirror it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", default="/var/lib/vz-builder")
    parser.add_argument("--control-sock", default=None)
    parser.add_argument("--internal-port", type=int, default=31123)
    parser.add_argument("--readiness-port", type=int, default=31124)
    parser.add_argument("--boot-timeout", type=float, default=90.0)
    parser.add_argument("--idle-timeout", type=float, default=60.0)
    parser.add_argument("--idle-poll", type=float, default=15.0)
    parser.add_argument("--vm-pid", type=int, required=True)
    parser.add_argument("--running-file", default=None)
    parser.add_argument("--vzvm-config", default=None)
    return parser.parse_args(argv)


def control_path(args: argparse.Namespace) -> anyio.Path:
    """The control socket, explicit or beside the rest of the state."""
    if args.control_sock is not None:
        return anyio.Path(args.control_sock)
    return anyio.Path(args.state_dir, "vzlink-control.sock")


def running_path(args: argparse.Namespace) -> anyio.Path:
    """The running-VM marker runVm wrote before exec."""
    if args.running_file is not None:
        return anyio.Path(args.running_file)
    return anyio.Path(args.state_dir, "running")


def alive(pid: int) -> bool:
    """Whether the VM process still runs.

    vzvm is this process's child (runVm forks it, then execs us), so a dead
    vzvm is a zombie until reaped, and `kill(pid, 0)` succeeds on a zombie.
    Reap first; fall back to the signal probe for a pid that is not ours.
    """
    try:
        reaped, _ = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    else:
        return reaped == 0
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


async def banner_probe(port: int) -> bytes:
    """The first bytes off the forwarded port. `SSH-` is the guest answering;
    anything else is vzvm holding the connection while the guest boots."""
    head = b""
    with anyio.fail_after(PROBE_TIMEOUT):
        async with await anyio.connect_tcp("127.0.0.1", port) as stream:
            while len(head) < len(BANNER):
                try:
                    head += await stream.receive(len(BANNER) - len(head))
                except anyio.EndOfStream:
                    break
    return head


async def readiness_probe(port: int) -> dict[str, Any]:
    """Ask the guest agent whether the builder serves. One JSON line."""
    with anyio.fail_after(PROBE_TIMEOUT):
        async with await anyio.connect_tcp("127.0.0.1", port) as stream:
            return await read_message(stream)


PROBE_ERRORS: Final = (OSError, TimeoutError, ProtocolError, *STREAM_ERRORS)


class Supervisor:
    """One VM's worth of state. Created once; the task group owns it."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.conns: dict[str, float] = {}
        self.boot_lock = anyio.Lock()
        self.booted: dict[str, Any] | None = None
        self.stop_reason = StopReason.IDLE
        self.stopping = False

    async def handle(self, stream: anyio.abc.SocketStream) -> None:
        """One RPC per connection: read a message, answer it, close."""
        async with stream:
            try:
                await send_message(stream, await self.dispatch(await read_message(stream)))
            except PeerClosed:
                pass
            except (ProtocolError, *STREAM_ERRORS) as exc:
                logger.warning("bad control message: %r", exc)

    async def dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        """Route on the request's `op`. An unknown op gets an error answer,
        never a hangup."""
        op = request.get("op")
        conn_id = str(request.get("id", "?"))
        if op == Op.ENSURE_UP:
            return await self.ensure_up()
        if op == Op.REGISTER:
            self.conns[conn_id] = time.monotonic()
            logger.info("register %s (%d live)", conn_id, len(self.conns))
            return ok(Op.REGISTER)
        if op == Op.UNREGISTER:
            self.conns.pop(conn_id, None)
            logger.info("unregister %s (%d live)", conn_id, len(self.conns))
            return ok(Op.UNREGISTER)
        return error(str(op), f"unknown op: {op!r}")

    async def ensure_up(self) -> dict[str, Any]:
        """Wait for the guest to serve builds. Concurrent asks during one boot
        share it. Only success is remembered: a failed boot is retried by the
        next ask instead of answered from a stale error."""
        async with self.boot_lock:
            if self.booted is not None:
                return self.booted
            answer = await self._boot()
            if answer["status"] == "ok":
                self.booted = answer
            return answer

    async def _boot(self) -> dict[str, Any]:
        """Two stages with one shared deadline: the SSH banner proves the VM
        answers, the readiness agent proves the builder serves."""
        start = time.monotonic()
        deadline = start + self.args.boot_timeout
        where = f"127.0.0.1:{self.args.internal_port}"
        within = f"within {self.args.boot_timeout:.0f}s"
        stages: list[dict[str, Any]] = []

        if not await self._wait_for_banner(deadline):
            return error(Op.ENSURE_UP, f"the guest did not answer on {where} {within} (no SSH banner)")
        stages.append({"stage": "banner", "seconds": round(time.monotonic() - start, 1)})

        reasons = await self._wait_for_ready(deadline)
        if reasons is not None:
            return error(
                Op.ENSURE_UP,
                f"the guest did not answer on {where} {within} (banner ok, builder not ready: {reasons})",
            )
        stages.append({"stage": "ready", "seconds": round(time.monotonic() - start, 1)})
        logger.info("guest ready: %s", stages)
        return ok(Op.ENSURE_UP, stages=stages)

    async def _wait_for_banner(self, deadline: float) -> bool:
        while time.monotonic() < deadline:
            try:
                if await banner_probe(self.args.internal_port) == BANNER:
                    return True
            except PROBE_ERRORS:
                pass
            await anyio.sleep(BANNER_POLL)
        return False

    async def _wait_for_ready(self, deadline: float) -> str | None:
        """None once the agent reports ready, else the last reasons seen, so
        the error names what was missing."""
        reasons = "no answer yet"
        while time.monotonic() < deadline:
            try:
                answer = await readiness_probe(self.args.readiness_port)
            except PROBE_ERRORS as exc:
                reasons = f"no answer: {exc!r}"
            else:
                if answer.get("status") == "ok" and answer.get("ready") is True:
                    return None
                reasons = ", ".join(str(r) for r in answer.get("reasons", ["not ready"]))
            await anyio.sleep(READY_POLL)
        return reasons

    async def _gone_within(self, seconds: float) -> bool:
        with anyio.move_on_after(seconds):
            while alive(self.args.vm_pid):
                await anyio.sleep(STOP_POLL)
            return True
        return False

    async def stop_vm(self) -> str:
        """SIGTERM, a bounded wait, then SIGKILL. vzvm answers SIGTERM by
        asking the guest to power off, so the first step is the clean one."""
        pid = self.args.vm_pid
        self.stopping = True
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return "already-dead"
        logger.info("stopping the VM (%s)", self.stop_reason)
        if await self._gone_within(STOP_GRACE):
            return "clean"
        logger.warning("guest did not stop within %.0fs; forcing", STOP_GRACE)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return "clean"
        return "forced" if await self._gone_within(KILL_GRACE) else "force-failed"

    async def idle_loop(self, scope: anyio.CancelScope) -> None:
        """Cancel `scope` when the VM has died or has been stopped for
        idleness. A boot in flight counts as activity: the proxy that asked
        has not registered yet."""
        await self._idle_loop()
        scope.cancel()

    async def _idle_loop(self) -> None:
        idle_for = 0.0
        while True:
            await anyio.sleep(self.args.idle_poll)
            if self.stopping:
                # The signal path is stopping the VM; its death is expected.
                continue
            if not alive(self.args.vm_pid):
                logger.error("the VM died; %d connection(s) were live", len(self.conns))
                self.stop_reason = StopReason.VM_DIED
                return
            if self.conns or self.boot_lock.locked():
                idle_for = 0.0
                continue
            idle_for += self.args.idle_poll
            if idle_for >= self.args.idle_timeout:
                logger.info("idle for %.0fs, shutting down", self.args.idle_timeout)
                self.stop_reason = StopReason.IDLE
                logger.info("stop outcome: %s", await self.stop_vm())
                return

    async def watch_signals(
        self,
        scope: anyio.CancelScope,
        *,
        task_status: anyio.abc.TaskStatus[None] = anyio.TASK_STATUS_IGNORED,
    ) -> None:
        """launchd stops this daemon with SIGTERM. Stop the VM the graceful
        way first, so a switch mid-build powers the guest off cleanly, then
        cancel `scope`. Reports started once the handler is installed."""
        with anyio.open_signal_receiver(signal.SIGTERM, signal.SIGINT) as signals:
            task_status.started()
            async for signum in signals:
                logger.info("received %s, stopping the VM", signal.Signals(signum).name)
                self.stop_reason = StopReason.SIGNAL
                logger.info("stop outcome: %s", await self.stop_vm())
                scope.cancel()
                return


async def cleanup(args: argparse.Namespace) -> None:
    """Remove the state files, so a dead VM never looks live. Idempotent:
    runVm's EXIT trap would remove the same files, but exec drops the trap."""
    paths = [running_path(args), control_path(args)]
    if args.vzvm_config is not None:
        paths.append(anyio.Path(args.vzvm_config))
    for path in paths:
        try:
            await path.unlink(missing_ok=True)
        except OSError as exc:
            logger.warning("cannot remove %s: %r", path, exc)


async def _amain(args: argparse.Namespace) -> int:
    sock_path = control_path(args)
    supervisor = Supervisor(args)
    logger.info(
        "supervising pid %d (boot-timeout %.0fs, idle-timeout %.0fs)",
        args.vm_pid,
        args.boot_timeout,
        args.idle_timeout,
    )
    try:
        async with anyio.create_task_group() as task_group:
            scope = task_group.cancel_scope
            # Before the bind: a proxy that sees the socket may already have
            # a launchd stop racing it, and SIGTERM must reach the handler.
            await task_group.start(supervisor.watch_signals, scope)
            try:
                await sock_path.unlink(missing_ok=True)
                listener = await anyio.create_unix_listener(str(sock_path))
            except OSError as exc:
                logger.error("cannot bind control socket %s: %r", sock_path, exc)
                scope.cancel()
                return 1
            task_group.start_soon(listener.serve, supervisor.handle)
            task_group.start_soon(supervisor.idle_loop, scope)
    finally:
        with anyio.CancelScope(shield=True):
            await cleanup(args)
    return 1 if supervisor.stop_reason is StopReason.VM_DIED else 0


def main(argv: list[str] | None = None) -> int:
    """Console script entry point. Returns the process exit code."""
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03d %(name)s %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S",
        stream=sys.stderr,
    )
    return anyio.run(_amain, args)


if __name__ == "__main__":
    sys.exit(main())
