"""Shared async JSON-RPC client for talking to a wrapty control socket."""

import asyncio
import os

from jsonrpc.jsonrpc2 import JSONRPC20Request, JSONRPC20Response


def runtime_dir() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "wrapty")


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
