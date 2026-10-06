"""Full-duplex byte forwarding between two anyio byte streams.

Half-close propagates: EOF on one side becomes `send_eof` on the other, and
the surviving direction keeps moving until its own EOF. That is what SSH
needs -- one side saying "done sending" must not kill the other direction.
An error in either direction ends both.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Final

import anyio

from vzlink.protocol import STREAM_ERRORS

if TYPE_CHECKING:
    from anyio.abc import ByteStream

CHUNK: Final = 65536


class EndedBy(StrEnum):
    """How a forwarded connection ended. Logged, so the values are stable."""

    EOF = "eof"
    ERROR = "error"


@dataclass
class ForwardStats:
    """What one forwarded connection moved, and how it ended."""

    a_to_b: int = 0
    b_to_a: int = 0
    ended_by: EndedBy = EndedBy.EOF
    detail: str = ""


class Activity:
    """Last-traffic timestamp, read by a stall monitor."""

    def __init__(self) -> None:
        self.last: float = time.monotonic()

    def touch(self) -> None:
        self.last = time.monotonic()


async def _receive(stream: ByteStream) -> bytes:
    """One chunk, or b"" at EOF. anyio raises EndOfStream there."""
    try:
        return await stream.receive(CHUNK)
    except anyio.EndOfStream:
        return b""


async def _copy(
    src: ByteStream,
    dst: ByteStream,
    stats: ForwardStats,
    attr: str,
    activity: Activity,
) -> None:
    """Move bytes one direction until EOF."""
    while chunk := await _receive(src):
        await dst.send(chunk)
        setattr(stats, attr, getattr(stats, attr) + len(chunk))
        activity.touch()
    # The peer may already be gone; its own direction reports that.
    try:
        await dst.send_eof()
    except STREAM_ERRORS:
        pass


def _describe(exc: BaseException) -> str:
    """anyio raises BrokenResourceError bare, with the OS error as the cause.
    The cause is the part worth logging: a reset reads differently from a
    broken pipe."""
    if exc.__cause__ is not None:
        return f"{type(exc).__name__}: {exc.__cause__!r}"
    return repr(exc)


async def forward(
    a: ByteStream, b: ByteStream, *, activity: Activity | None = None
) -> ForwardStats:
    """Copy both directions until both reach EOF, then close both streams.

    `activity`, when given, is touched on every chunk so a monitor can tell a
    stalled connection from a quiet one.
    """
    seen = activity if activity is not None else Activity()
    seen.touch()
    stats = ForwardStats()
    try:
        async with anyio.create_task_group() as task_group:
            task_group.start_soon(_copy, a, b, stats, "a_to_b", seen)
            task_group.start_soon(_copy, b, a, stats, "b_to_a", seen)
    except* STREAM_ERRORS as group:
        stats.ended_by = EndedBy.ERROR
        stats.detail = "; ".join(_describe(exc) for exc in group.exceptions)
    finally:
        with anyio.CancelScope(shield=True):
            await a.aclose()
            await b.aclose()
    return stats
