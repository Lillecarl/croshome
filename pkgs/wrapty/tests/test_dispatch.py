"""_dispatch turns one line off the control socket into one JSON-RPC response.

It must never raise: it runs inside a connection coroutine, and an exception
there reaches the event loop handler, which is how a traceback used to land on
the terminal the wrapped TUI is drawing on.
"""

import asyncio
import json

import pytest
from jsonrpc import Dispatcher

from wrapty import wrapper as wrapty

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
SERVER_ERROR = -32000


@pytest.fixture
def dispatcher():
    d = Dispatcher()

    @d.add_method
    def echo(text):
        return text

    @d.add_method
    async def slow_echo(text):
        await asyncio.sleep(0)
        return text

    @d.add_method
    def explode():
        raise RuntimeError("boom")

    return d


def dispatch(line, dispatcher):
    return asyncio.run(wrapty._dispatch(line, dispatcher))


def request(method, params=None, _id=1):
    return json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": _id}
    )


def test_a_valid_call_returns_its_result(dispatcher):
    response = dispatch(request("echo", {"text": "hi"}), dispatcher)
    assert response.result == "hi"
    assert response.error is None


def test_a_coroutine_method_is_awaited(dispatcher):
    """send() depends on this: the caller is told "ok" once the text has
    actually been typed, not once typing started."""
    response = dispatch(request("slow_echo", {"text": "hi"}), dispatcher)
    assert response.result == "hi"


def test_an_unknown_method_is_reported_as_such(dispatcher):
    response = dispatch(request("nope"), dispatcher)
    assert response.error["code"] == METHOD_NOT_FOUND


def test_a_method_that_raises_becomes_a_server_error(dispatcher):
    response = dispatch(request("explode"), dispatcher)
    assert response.error["code"] == SERVER_ERROR
    assert response.error["data"]["type"] == "RuntimeError"
    assert response.error["data"]["message"] == "boom"


def test_a_line_that_is_not_json_becomes_a_parse_error(dispatcher):
    response = dispatch("this is not json", dispatcher)
    assert response.error["code"] == PARSE_ERROR
    assert response._id is None


def test_a_truncated_line_becomes_a_parse_error(dispatcher):
    response = dispatch('{"jsonrpc": "2.0", "meth', dispatcher)
    assert response.error["code"] == PARSE_ERROR


@pytest.mark.parametrize(
    "line",
    [
        '{"foo": 1}',  # an object, but not a request
        "[]",  # a batch, which this dispatcher does not accept
        "null",
        '{"jsonrpc": "2.0", "method": 1, "id": 1}',  # method must be a string
    ],
)
def test_json_that_is_not_a_request_becomes_an_invalid_request(line, dispatcher):
    response = dispatch(line, dispatcher)
    assert response.error["code"] == INVALID_REQUEST
    assert response._id is None
