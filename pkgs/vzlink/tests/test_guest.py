"""The guest readiness agent: checks against temp dirs, and one probe served
over loopback instead of vsock -- the serve loop takes any listening stream
socket for exactly this."""

from __future__ import annotations

import socket
from functools import partial

import anyio
import pytest

from vzlink import guest
from vzlink.protocol import Op, read_message

from conftest import DEADLINE


@pytest.mark.anyio
async def test_ready_when_daemon_serves(tmp_path) -> None:
    daemon_socket = tmp_path / "daemon-socket"
    daemon_socket.write_text("x")
    store = tmp_path / "store"
    store.mkdir()
    (store / "some-path").write_text("x")

    ready, reasons = await guest.readiness(
        daemon_socket=str(daemon_socket), store_dir=str(store)
    )
    assert ready is True
    assert reasons == []


@pytest.mark.anyio
async def test_not_ready_names_what_is_missing(tmp_path) -> None:
    ready, reasons = await guest.readiness(
        daemon_socket=str(tmp_path / "nope"),
        store_dir=str(tmp_path / "alsono"),
    )
    assert ready is False
    assert "daemon-socket-missing" in reasons
    assert "store-not-mounted" in reasons


@pytest.mark.anyio
async def test_serve_answers_one_probe(tmp_path) -> None:
    daemon_socket = tmp_path / "daemon-socket"
    daemon_socket.write_text("x")
    store = tmp_path / "store"
    store.mkdir()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    port = listener.getsockname()[1]

    with anyio.fail_after(DEADLINE):
        async with anyio.create_task_group() as task_group:
            task_group.start_soon(
                partial(
                    guest.serve,
                    listener,
                    daemon_socket=str(daemon_socket),
                    store_dir=str(store),
                )
            )
            for _ in range(2):
                async with await anyio.connect_tcp("127.0.0.1", port) as stream:
                    answer = await read_message(stream)
                assert answer["op"] == Op.READINESS.value
                assert answer["status"] == "ok"
                assert answer["ready"] is True
            task_group.cancel_scope.cancel()
    assert listener.fileno() == -1


def test_vsock_guard_on_platforms_without_vsock(monkeypatch) -> None:
    """The factory raises RuntimeError, not AttributeError, where vsock does
    not exist -- which is every platform but the guest."""
    monkeypatch.delattr(socket, "AF_VSOCK", raising=False)
    monkeypatch.delattr(socket, "VMADDR_CID_ANY", raising=False)
    with pytest.raises(RuntimeError, match="vsock"):
        guest.vsock_listener(11123)
