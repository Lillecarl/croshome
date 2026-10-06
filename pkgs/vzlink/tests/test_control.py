"""Supervisor and proxy against fakes: a banner-and-echo guest, a readiness
agent that always answers ready, and a sleeping Python standing in for vzvm.

The fakes serve real listeners in the test's task group, and the supervisor
and proxy run as anyio.open_process children -- the same modules the console
scripts the nix module execs point at.
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import subprocess
import sys
from contextlib import asynccontextmanager

import anyio
import anyio.abc
import pytest
from anyio.abc import SocketAttribute

from vzlink import supervisor
from vzlink.protocol import STREAM_ERRORS, Op, VmStopping, check_response, read_message, send_message

from conftest import DEADLINE

BANNER = b"SSH-2.0-fake\r\n"


async def _echo_handler(stream: anyio.abc.SocketStream) -> None:
    """Banner, then echo: the two things the supervisor and proxy need."""
    async with stream:
        try:
            await stream.send(BANNER)
            while True:
                await stream.send(await stream.receive())
        except (anyio.EndOfStream, *STREAM_ERRORS):
            return


async def _ready_handler(stream: anyio.abc.SocketStream) -> None:
    """One ready line, then close -- like the guest agent."""
    async with stream:
        try:
            await send_message(stream, {"op": "readiness", "status": "ok", "ready": True, "reasons": []})
        except STREAM_ERRORS:
            pass


@asynccontextmanager
async def _fake_guest():
    """Serves the banner port and the readiness port. Yields both ports."""
    async with (
        await anyio.create_tcp_listener(local_host="127.0.0.1") as guest,
        await anyio.create_tcp_listener(local_host="127.0.0.1") as ready,
        anyio.create_task_group() as task_group,
    ):
        task_group.start_soon(guest.serve, _echo_handler)
        task_group.start_soon(ready.serve, _ready_handler)
        yield guest.extra(SocketAttribute.local_port), ready.extra(SocketAttribute.local_port)
        task_group.cancel_scope.cancel()


class Child:
    """A child process whose stderr is drained as it runs, so a full pipe
    can never stall it."""

    def __init__(self, proc: anyio.abc.Process) -> None:
        self.proc = proc
        self.stderr = bytearray()

    async def drain(self) -> None:
        if self.proc.stderr is None:
            return
        async for chunk in self.proc.stderr:
            self.stderr += chunk

    @property
    def log(self) -> str:
        return self.stderr.decode(errors="replace")

    async def wait(self) -> int:
        """Wait for exit, bounded. A child that outlives the deadline is
        killed and the test fails."""
        with anyio.move_on_after(DEADLINE):
            return await self.proc.wait()
        self.proc.kill()
        await self.proc.wait()
        raise TimeoutError(f"child did not exit in time:\n{self.log}")


@asynccontextmanager
async def _child(argv: list[str], **kwargs):
    proc = await anyio.open_process(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, **kwargs)
    child = Child(proc)
    async with proc, anyio.create_task_group() as task_group:
        task_group.start_soon(child.drain)
        try:
            yield child
        finally:
            with anyio.CancelScope(shield=True):
                if proc.returncode is None:
                    proc.terminate()
                await child.wait()


@asynccontextmanager
async def _fake_vm():
    """A process with a pid that answers to SIGTERM, standing in for vzvm."""
    async with _child([sys.executable, "-c", "import time; time.sleep(120)"]) as vm:
        yield vm


SLOW_STOP_VM = """
import signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: (time.sleep(2), sys.exit(0)))
time.sleep(120)
"""


@asynccontextmanager
async def _supervisor(state_dir: str, guest_port: int, readiness_port: int, vm_pid: int, *, idle_timeout: float = 30.0):
    """The real supervisor module as a child. Yields it and its control socket."""
    running = anyio.Path(state_dir, "running")
    config = anyio.Path(state_dir, "vzvm.json")
    await running.write_text("x\n")
    await config.write_text("x\n")
    argv = [
        sys.executable, "-m", "vzlink.supervisor",
        "--state-dir", state_dir,
        "--internal-port", str(guest_port),
        "--readiness-port", str(readiness_port),
        "--boot-timeout", "10",
        "--idle-timeout", str(idle_timeout),
        "--idle-poll", "0.5",
        "--vm-pid", str(vm_pid),
        "--running-file", str(running),
        "--vzvm-config", str(config),
    ]  # fmt: skip
    sock_path = anyio.Path(state_dir, "vzlink-control.sock")
    async with _child(argv) as proc:
        while not await sock_path.exists():
            if proc.proc.returncode is not None:
                raise RuntimeError(f"supervisor exited early:\n{proc.log}")
            await anyio.sleep(0.05)
        yield proc, str(sock_path)


async def _rpc(sock_path: str, payload: dict) -> dict:
    async with await anyio.connect_unix(sock_path) as stream:
        await send_message(stream, payload)
        return await read_message(stream)


@pytest.mark.anyio
async def test_ensure_up_reports_stages(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_guest() as (guest_port, readiness_port), _fake_vm() as vm:
            async with _supervisor(state_dir, guest_port, readiness_port, vm.proc.pid) as (_, sock):
                answer = await _rpc(sock, {"op": Op.ENSURE_UP.value, "id": "t1"})
                info = check_response(answer, Op.ENSURE_UP)
                assert [s["stage"] for s in info["stages"]] == ["banner", "ready"]


@pytest.mark.anyio
async def test_unknown_op_names_itself(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm, _supervisor(state_dir, 9, 9, vm.proc.pid) as (_, sock):
            answer = await _rpc(sock, {"op": "frobnicate"})
            assert answer == {"op": "frobnicate", "status": "error", "message": "unknown op: 'frobnicate'"}


@pytest.mark.anyio
async def test_liveness_probe_is_silent(state_dir) -> None:
    """The proxy waits for the supervisor by connecting and closing. That is
    a probe, not a malformed message; only a half line is worth a warning."""
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm, _supervisor(state_dir, 9, 9, vm.proc.pid) as (sup, sock):
            await (await anyio.connect_unix(sock)).aclose()
            async with await anyio.connect_unix(sock) as stream:
                await stream.send(b'{"op":')
                await stream.send_eof()
                with pytest.raises(anyio.EndOfStream):
                    await stream.receive()
            sup.proc.terminate()
            await sup.wait()
            assert sup.log.count("bad control message") == 1


@pytest.mark.anyio
async def test_register_then_idle_shutdown(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm:
            async with _supervisor(state_dir, 9, 9, vm.proc.pid, idle_timeout=2.0) as (sup, sock):
                check_response(await _rpc(sock, {"op": Op.REGISTER.value, "id": "c1"}), Op.REGISTER)
                # Held past the idle timeout: a registered connection keeps the VM.
                await anyio.sleep(3.0)
                assert sup.proc.returncode is None
                check_response(await _rpc(sock, {"op": Op.UNREGISTER.value, "id": "c1"}), Op.UNREGISTER)

                assert await sup.wait() == 0
                assert "register c1 (1 live)" in sup.log
                assert "unregister c1 (0 live)" in sup.log
                assert "shutting down" in sup.log
                # SIGTERM, not SIGKILL: a negative returncode is the signal.
                assert await vm.wait() == -signal.SIGTERM
                # A dead VM never looks live.
                assert not await anyio.Path(state_dir, "running").exists()
                assert not await anyio.Path(state_dir, "vzvm.json").exists()
                assert not await anyio.Path(sock).exists()


@pytest.mark.anyio
async def test_sigterm_stops_vm(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm, _supervisor(state_dir, 9, 9, vm.proc.pid) as (sup, _):
            sup.proc.terminate()
            assert await sup.wait() == 0
            assert await vm.wait() == -signal.SIGTERM
            assert "stopping the VM (signal)" in sup.log


@pytest.mark.anyio
async def test_vm_death_exits_nonzero(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm, _supervisor(state_dir, 9, 9, vm.proc.pid) as (sup, _):
            vm.proc.kill()
            assert await sup.wait() == 1
            assert "the VM died" in sup.log


@pytest.mark.anyio
async def test_proxy_forwards_and_logs(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        async with _fake_guest() as (guest_port, readiness_port), _fake_vm() as vm:
            async with _supervisor(state_dir, guest_port, readiness_port, vm.proc.pid) as (sup, sock):
                client_end, proxy_end = socket.socketpair()
                argv = [
                    sys.executable, "-m", "vzlink.proxy",
                    "--control-sock", sock,
                    "--internal-port", str(guest_port),
                    "--boot-timeout", "10",
                    "--kickstart-cmd", "true",
                ]  # fmt: skip
                async with _child(argv, stdin=proxy_end) as proxy:
                    proxy_end.close()
                    async with await anyio.abc.UNIXSocketStream.from_socket(client_end) as client:
                        await client.send(b"hello-proxy")
                        # The guest banners first, like sshd; the proxy
                        # forwards blindly, so the banner precedes the echo.
                        expected = BANNER + b"hello-proxy"
                        got = b""
                        while len(got) < len(expected):
                            got += await client.receive()
                        assert got == expected
                        await client.send_eof()
                        with pytest.raises(anyio.EndOfStream):
                            await client.receive()

                    assert await proxy.wait() == 0
                    assert "guest ready after" in proxy.log
                    assert "closed: eof" in proxy.log
                    assert f"up=11 down={len(expected)}" in proxy.log
                assert "unregister" in sup.log and "(0 live)" in sup.log


@pytest.mark.anyio
async def test_proxy_waits_out_a_stopping_vm(state_dir) -> None:
    """A proxy that arrives while the VM is stopping must not register with
    it -- the connection would die with the VM. It waits for that
    supervisor to leave and is served by the next one."""
    with anyio.fail_after(DEADLINE):
        async with _fake_guest() as (guest_port, readiness_port):
            async with _child([sys.executable, "-c", SLOW_STOP_VM]) as old_vm:
                async with _supervisor(state_dir, guest_port, readiness_port, old_vm.proc.pid) as (old, sock):
                    check_response(await _rpc(sock, {"op": Op.ENSURE_UP.value, "id": "warm"}), Op.ENSURE_UP)
                    old.proc.terminate()
                    while "stopping the VM" not in old.log:
                        await anyio.sleep(0.05)

                    client_end, proxy_end = socket.socketpair()
                    argv = [
                        sys.executable, "-m", "vzlink.proxy",
                        "--control-sock", sock,
                        "--internal-port", str(guest_port),
                        "--boot-timeout", "20",
                        "--kickstart-cmd", "true",
                    ]  # fmt: skip
                    async with _child(argv, stdin=proxy_end) as proxy:
                        proxy_end.close()
                        assert await old.wait() == 0
                        async with _fake_vm() as new_vm:
                            async with _supervisor(state_dir, guest_port, readiness_port, new_vm.proc.pid) as (new, _):
                                async with await anyio.abc.UNIXSocketStream.from_socket(client_end) as client:
                                    got = b""
                                    try:
                                        while len(got) < len(BANNER):
                                            got += await client.receive()
                                    except anyio.EndOfStream:
                                        await proxy.wait()
                                        pytest.fail(
                                            f"proxy closed the client\n--- proxy\n{proxy.log}"
                                            f"--- old\n{old.log}--- new\n{new.log}"
                                        )
                                    assert got == BANNER
                                    await client.send_eof()
                                    with pytest.raises(anyio.EndOfStream):
                                        while True:
                                            await client.receive()
                                assert await proxy.wait() == 0
                                assert "the VM is stopping" in proxy.log
                                assert "refused ensure_up" in old.log
                                assert "register" in new.log


@pytest.mark.anyio
async def test_stopping_supervisor_refuses_new_work() -> None:
    sup = supervisor.Supervisor(_args())
    sup.stopping = True
    for op in (Op.ENSURE_UP, Op.REGISTER):
        answer = await sup.dispatch({"op": op.value, "id": "late"})
        assert answer["status"] == "stopping"
        with pytest.raises(VmStopping):
            check_response(answer, op)
    # A connection that is already live still says goodbye.
    assert (await sup.dispatch({"op": Op.UNREGISTER.value, "id": "late"}))["status"] == "ok"


@pytest.mark.anyio
async def test_proxy_fails_cleanly_without_supervisor(state_dir) -> None:
    with anyio.fail_after(DEADLINE):
        client_end, proxy_end = socket.socketpair()
        argv = [
            sys.executable, "-m", "vzlink.proxy",
            "--control-sock", os.path.join(state_dir, "absent.sock"),
            "--boot-timeout", "1",
            "--kickstart-cmd", "true",
        ]  # fmt: skip
        async with _child(argv, stdin=proxy_end) as proxy:
            proxy_end.close()
            async with await anyio.abc.UNIXSocketStream.from_socket(client_end) as client:
                with pytest.raises(anyio.EndOfStream):
                    await client.receive()
            assert await proxy.wait() == 1
            assert "supervisor never appeared" in proxy.log


def _args(**overrides) -> argparse.Namespace:
    args = supervisor.parse_args(["--vm-pid", str(os.getpid())])
    for key, value in overrides.items():
        setattr(args, key, value)
    return args


@pytest.mark.anyio
async def test_failed_boot_is_not_cached() -> None:
    """A boot that timed out is retried by the next ask, not answered from
    the stale error."""
    with anyio.fail_after(DEADLINE):
        sup = supervisor.Supervisor(_args(internal_port=9, readiness_port=9, boot_timeout=0.5))
        answer = await sup.ensure_up()
        assert answer["status"] == "error"
        assert "did not answer on 127.0.0.1:9 within 0s (no SSH banner)" in answer["message"]

        async with _fake_guest() as (guest_port, readiness_port):
            sup.args.internal_port = guest_port
            sup.args.readiness_port = readiness_port
            sup.args.boot_timeout = 10.0
            assert (await sup.ensure_up())["status"] == "ok"


@pytest.mark.anyio
async def test_boot_in_flight_is_not_idle() -> None:
    """An ensure_up in progress holds the VM: the proxy that asked has not
    registered yet, and stopping the VM under it fails the build."""
    with anyio.fail_after(DEADLINE):
        async with _fake_vm() as vm:
            sup = supervisor.Supervisor(_args(vm_pid=vm.proc.pid, idle_timeout=0.3, idle_poll=0.1))
            async with sup.boot_lock, anyio.create_task_group() as task_group:
                task_group.start_soon(sup.idle_loop, task_group.cancel_scope)
                await anyio.sleep(1.0)
                assert vm.proc.returncode is None
                task_group.cancel_scope.cancel()


@pytest.mark.anyio
async def test_alive_reaps_a_dead_child() -> None:
    """vzvm is the supervisor's child. Unreaped, a dead one is a zombie that
    `kill(pid, 0)` still finds, so the VM would look alive forever."""
    pid = os.posix_spawn(sys.executable, [sys.executable, "-c", "pass"], os.environ)
    with anyio.fail_after(DEADLINE):
        while supervisor.alive(pid):
            await anyio.sleep(0.05)
    with pytest.raises(ChildProcessError):
        os.waitpid(pid, os.WNOHANG)
