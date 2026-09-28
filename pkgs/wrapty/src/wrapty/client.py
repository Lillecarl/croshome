"""Shared async JSON-RPC client for talking to a wrapty control socket."""

import asyncio
import os

from jsonrpc.jsonrpc2 import JSONRPC20Request, JSONRPC20Response


DISABLE_ENV = "WRAPTY_DISABLE"


def disabled() -> bool:
    return os.environ.get(DISABLE_ENV) == "1"


def session_id() -> str | None:
    """The wrapty session this process belongs to, or None.

    None outside wrapty, and under WRAPTY_DISABLE=1. WAPTY_ID is inherited by
    everything a wrapped session spawns, so a daemon started from one passes
    it on to every agent it runs, and their hooks reach this session's control
    socket. WRAPTY_DISABLE=1 cuts that link for a whole process tree.
    """
    if disabled():
        return None
    return os.environ.get("WAPTY_ID") or None


def runtime_dir() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "wrapty")


def state_dir() -> str:
    """Where wrapty keeps what has to outlive the session.

    Not runtime_dir: that is a tmpfs, emptied when the login session ends.
    The journal is read days later, across sessions that are long gone.
    """
    return os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "wrapty",
    )


async def call(session_id: str, method: str, params: dict | None = None):
    sock_path = os.path.join(runtime_dir(), f"{session_id}.sock")
    request = JSONRPC20Request(method=method, params=params or {}, _id=1)

    reader, writer = await asyncio.open_unix_connection(sock_path)
    try:
        writer.write(request.json.encode() + b"\n")
        await writer.drain()
        line = await reader.readline()
    finally:
        writer.close()
        await writer.wait_closed()

    response = JSONRPC20Response.from_json(line.decode())
    if response.error is not None:
        raise RuntimeError(response.error.get("message", "unknown error"))
    return response.result
