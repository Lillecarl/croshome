"""The control socket, driven by a real client over a real unix socket.

The property under test is the one the terminal depends on: no matter what a
caller does, nothing escapes _handle_client. wrapty's stderr is the terminal,
and the wrapped child is a full-screen TUI that never learns text arrived
there, so an escaped exception leaves the display corrupt until a resize.

Each test asserts `escaped == []`. That list is filled by the loop's exception
handler, which is exactly where asyncio would have sent a traceback.
"""

import asyncio
import json
import socket
import struct

import pytest
from jsonrpc import Dispatcher

from wrapty import wrapper as wrapty


def serve(tmp_path, client):
    """Run the real connection handler against `client`, a blocking function
    that gets the socket path. Returns (client result, escaped exceptions)."""
    sock_path = str(tmp_path / "control.sock")
    escaped = []

    dispatcher = Dispatcher()
    dispatcher["ping"] = lambda: "pong"

    async def main():
        loop = asyncio.get_running_loop()
        loop.set_exception_handler(lambda loop, context: escaped.append(context))
        server = await asyncio.start_unix_server(
            lambda r, w: wrapty._handle_client(r, w, dispatcher), path=sock_path
        )
        try:
            result = await asyncio.wait_for(
                asyncio.to_thread(client, sock_path), timeout=10
            )
            # Give the handler a turn to finish, so a late traceback still
            # lands in `escaped` before the assertions run.
            await asyncio.sleep(0.1)
            return result
        finally:
            server.close()
            # Every wait here is capped on purpose. A handler that lets an
            # exception escape never closes its connection, and wait_closed()
            # then blocks for as long as the process lives -- which turns a
            # regression into a build that hangs instead of a suite that
            # fails. Measured: reverting the fix wedged the check phase until
            # a 900s timeout killed it.
            try:
                await asyncio.wait_for(server.wait_closed(), timeout=5)
            except TimeoutError:
                pass

    return asyncio.run(main()), escaped


PING = json.dumps({"jsonrpc": "2.0", "method": "ping", "params": {}, "id": 1}).encode()


def send(sock_path, payload, read=True, reset=False):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if reset:
        # Close abortively (RST) rather than with a FIN, so the server's write
        # fails outright instead of draining into a half-closed socket.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.connect(sock_path)
    try:
        s.sendall(payload)
        if read:
            s.settimeout(5)
            return s.recv(65536).decode()
    finally:
        s.close()
    return None


def test_a_valid_request_is_answered(tmp_path):
    reply, escaped = serve(tmp_path, lambda p: send(p, PING + b"\n"))
    assert json.loads(reply)["result"] == "pong"
    assert escaped == []


def test_a_malformed_line_is_answered_not_raised(tmp_path):
    reply, escaped = serve(tmp_path, lambda p: send(p, b"this is not json\n"))
    assert json.loads(reply)["error"]["code"] == -32700
    assert escaped == []


def test_undecodable_bytes_are_answered_not_raised(tmp_path):
    """A truncated multi-byte character must not reach .decode() unguarded."""
    reply, escaped = serve(tmp_path, lambda p: send(p, b"\xff\xfe broken\n"))
    assert json.loads(reply)["error"]["code"] == -32700
    assert escaped == []


def test_a_caller_that_leaves_before_reading_is_silent(tmp_path):
    """The statusline does this. Claude Code starts it and does not wait."""
    _, escaped = serve(tmp_path, lambda p: send(p, PING + b"\n", read=False))
    assert escaped == []


def test_a_caller_that_resets_the_connection_is_silent(tmp_path):
    _, escaped = serve(tmp_path, lambda p: send(p, PING + b"\n", read=False, reset=True))
    assert escaped == []


def test_several_requests_on_one_connection(tmp_path):
    def client(sock_path):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.settimeout(5)
        try:
            s.sendall(PING + b"\n" + b"not json\n" + PING + b"\n")
            data = b""
            while data.count(b"\n") < 3:
                data += s.recv(65536)
            return data.decode()
        finally:
            s.close()

    replies, escaped = serve(tmp_path, client)
    codes = [json.loads(line) for line in replies.strip().split("\n")]
    assert codes[0]["result"] == "pong"
    assert codes[1]["error"]["code"] == -32700
    # A bad line must not poison the rest of the connection.
    assert codes[2]["result"] == "pong"
    assert escaped == []
