"""The forwarder, over real loopback TCP: counts, half-close, error paths."""

from __future__ import annotations

import socket
import struct
from contextlib import asynccontextmanager

import anyio
import anyio.abc
import pytest
from anyio.abc import SocketAttribute

from vzlink.forward import Activity, EndedBy, ForwardStats, forward

from conftest import DEADLINE


async def _pair(listener: anyio.abc.SocketListener) -> tuple[anyio.abc.SocketStream, anyio.abc.SocketStream]:
    port = listener.extra(SocketAttribute.local_port)
    outer = await anyio.connect_tcp("127.0.0.1", port)
    inner = await listener.accept()
    return outer, inner


@asynccontextmanager
async def _forwarding(activity: Activity | None = None):
    """Two client ends with a forwarder between them. Yields the ends and a
    slot that holds the stats once the forwarder returns."""
    slot: dict[str, ForwardStats] = {}
    async with await anyio.create_tcp_listener(local_host="127.0.0.1") as multi:
        (listener,) = multi.listeners
        client_a, side_a = await _pair(listener)
        client_b, side_b = await _pair(listener)

    async def run() -> None:
        slot["stats"] = await forward(side_a, side_b, activity=activity)

    with anyio.fail_after(DEADLINE):
        async with anyio.create_task_group() as task_group:
            task_group.start_soon(run)
            try:
                yield client_a, client_b, slot
            finally:
                await client_a.aclose()
                await client_b.aclose()


async def _read_exactly(stream: anyio.abc.ByteReceiveStream, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        buf += await stream.receive(n - len(buf))
    return buf


@pytest.mark.anyio
async def test_roundtrip_counts_both_directions() -> None:
    async with _forwarding() as (client_a, client_b, slot):
        await client_a.send(b"hello")
        assert await _read_exactly(client_b, 5) == b"hello"
        await client_b.send(b"world!")
        assert await _read_exactly(client_a, 6) == b"world!"

        # Half-close: a is done sending, b still talks back.
        await client_a.send_eof()
        with pytest.raises(anyio.EndOfStream):
            await client_b.receive()
        await client_b.send(b"late")
        assert await _read_exactly(client_a, 4) == b"late"
        await client_b.send_eof()
        with pytest.raises(anyio.EndOfStream):
            await client_a.receive()

    stats = slot["stats"]
    assert (stats.a_to_b, stats.b_to_a) == (5, 10)
    assert stats.ended_by is EndedBy.EOF


@pytest.mark.anyio
async def test_small_messages_are_not_held_for_a_full_read() -> None:
    """The read size caps a read; it is not a fill target. The nix protocol
    sends small frames and waits for answers, so a read that waited for a
    full chunk would deadlock it. One-byte round trips must flow at once."""
    async with _forwarding() as (client_a, client_b, _):
        with anyio.fail_after(2.0):
            for i in range(200):
                byte = bytes([i])
                await client_a.send(byte)
                assert await client_b.receive() == byte
                await client_b.send(byte)
                assert await client_a.receive() == byte


@pytest.mark.anyio
async def test_activity_touched_by_traffic() -> None:
    activity = Activity()
    activity.last = 0.0
    async with _forwarding(activity) as (client_a, client_b, _):
        await client_a.send(b"x")
        assert await _read_exactly(client_b, 1) == b"x"
        assert activity.last > 0.0


@pytest.mark.anyio
async def test_abrupt_close_reports_error() -> None:
    """A peer that dies mid-stream is `error`, not `eof` -- the log line must
    tell a crash apart from a clean goodbye.

    The dying peer is a bare socket: anyio's aclose sends FIN before closing,
    and the forwarder rightly reads that as EOF. SO_LINGER zero on a bare
    close sends RST alone."""
    slot: dict[str, ForwardStats] = {}
    async with await anyio.create_tcp_listener(local_host="127.0.0.1") as multi:
        (listener,) = multi.listeners
        port = listener.extra(SocketAttribute.local_port)
        dying = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dying.setblocking(False)
        dying.connect_ex(("127.0.0.1", port))
        side_a = await listener.accept()
        await anyio.wait_writable(dying)
        client_b, side_b = await _pair(listener)

    async def run() -> None:
        slot["stats"] = await forward(side_a, side_b)

    with anyio.fail_after(DEADLINE):
        async with client_b, anyio.create_task_group() as task_group:
            task_group.start_soon(run)
            dying.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            dying.close()

    stats = slot["stats"]
    assert stats.ended_by is EndedBy.ERROR
    assert "ConnectionResetError" in stats.detail
