"""Newline-delimited JSON framing shared by the proxy, the supervisor and the
guest agent. The wire shape is one JSON object per line; anything else is a
protocol error, never a silent drop.
"""

from __future__ import annotations

import json
import os
import time
from enum import StrEnum
from typing import Any, Final

import anyio
import anyio.abc

MAX_LINE: Final = 1024 * 1024


class Op(StrEnum):
    """Every request one side may send the other."""

    ENSURE_UP = "ensure_up"
    REGISTER = "register"
    UNREGISTER = "unregister"
    READINESS = "readiness"


class Status(StrEnum):
    """Every response carries one of these."""

    OK = "ok"
    ERROR = "error"


class ProtocolError(ValueError):
    """The peer sent bytes that are not one JSON object per line."""


class PeerClosed(ProtocolError):
    """The peer closed without sending a byte. The proxy's wait for the
    supervisor does exactly this, so a server treats it as a probe."""


class ControlError(RuntimeError):
    """The peer answered, with Status.ERROR."""


STREAM_ERRORS: Final = (OSError, anyio.ClosedResourceError, anyio.BrokenResourceError)
"""Everything a stream operation raises when the peer goes away mid-talk:
the socket error, the clean close, and the RST. Handlers catch this tuple
so one dead connection cannot take down the task group serving the rest."""


def encode(obj: dict[str, Any]) -> bytes:
    """One message on the wire: compact JSON plus the newline delimiter."""
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode()


def decode_line(line: bytes) -> dict[str, Any]:
    """Parse one line back into the object. Raises ProtocolError, never
    returns a half value."""
    if len(line) > MAX_LINE:
        raise ProtocolError(f"line of {len(line)} bytes exceeds {MAX_LINE}")
    try:
        obj = json.loads(line.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"not a JSON object: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError(f"not an object: {type(obj).__name__}")
    return obj


async def send_message(stream: anyio.abc.ByteStream, obj: dict[str, Any]) -> None:
    """Write one message. anyio streams only; the socket stays open."""
    await stream.send(encode(obj))


async def read_message(stream: anyio.abc.ByteStream) -> dict[str, Any]:
    """Read until the newline delimiter. Raises ProtocolError when the peer
    closes first or the line runs past MAX_LINE."""
    buf = bytearray()
    while True:
        try:
            chunk = await stream.receive(65536)
        except anyio.EndOfStream:
            chunk = b""
        if not chunk and not buf:
            raise PeerClosed("peer closed without sending")
        if not chunk:
            raise ProtocolError("peer closed before the newline delimiter")
        buf += chunk
        if b"\n" in buf:
            line, _, _ = bytes(buf).partition(b"\n")
            return decode_line(line)
        if len(buf) > MAX_LINE:
            raise ProtocolError(f"line exceeds {MAX_LINE} bytes with no delimiter")


def check_response(obj: dict[str, Any], op: Op) -> dict[str, Any]:
    """Unwrap an answer to `op`. Status.ERROR becomes ControlError carrying
    the peer's message; a wrong or missing shape becomes ProtocolError."""
    if obj.get("op") != op.value:
        raise ProtocolError(f"answer is for {obj.get('op')!r}, not {op.value!r}")
    if obj.get("status") == Status.ERROR.value:
        raise ControlError(str(obj.get("message", "no message")))
    if obj.get("status") != Status.OK.value:
        raise ProtocolError(f"answer has no status: {obj!r}")
    return obj


def ok(op: Op, **fields: Any) -> dict[str, Any]:
    """Build a Status.OK answer."""
    return {"op": op.value, "status": Status.OK.value, **fields}


def error(op: Op | str, message: str) -> dict[str, Any]:
    """Build a Status.ERROR answer. A plain string echoes an op the peer
    sent that is not an Op, so its answer still names its own request."""
    return {"op": str(op), "status": Status.ERROR.value, "message": message}


def new_conn_id() -> str:
    """Unique per proxied connection: the pid plus a monotonic timestamp."""
    return f"{os.getpid()}-{time.monotonic_ns()}"
