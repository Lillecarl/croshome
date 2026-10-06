"""The framing: one JSON object per line, and errors that say what was wrong."""

from __future__ import annotations

import pytest

from vzlink.protocol import (
    ControlError,
    Op,
    ProtocolError,
    check_response,
    decode_line,
    encode,
    error,
    new_conn_id,
    ok,
)


def test_roundtrip() -> None:
    obj = {"op": "register", "id": "7-123", "n": 3, "flag": True}
    assert decode_line(encode(obj)) == obj


def test_line_ends_with_newline() -> None:
    assert encode({"a": 1}).endswith(b"\n")


def test_not_json() -> None:
    with pytest.raises(ProtocolError):
        decode_line(b"hello\n")


def test_not_an_object() -> None:
    with pytest.raises(ProtocolError):
        decode_line(b"[1, 2]\n")


def test_not_utf8() -> None:
    with pytest.raises(ProtocolError):
        decode_line(b"\xff\xfe\n")


def test_check_ok() -> None:
    answer = ok(Op.ENSURE_UP, stages=[{"stage": "banner"}])
    assert check_response(answer, Op.ENSURE_UP)["stages"] == [{"stage": "banner"}]


def test_check_error() -> None:
    with pytest.raises(ControlError, match="guest did not answer"):
        check_response(error(Op.ENSURE_UP, "guest did not answer"), Op.ENSURE_UP)


def test_check_wrong_op() -> None:
    with pytest.raises(ProtocolError):
        check_response(ok(Op.REGISTER), Op.ENSURE_UP)


def test_check_missing_status() -> None:
    with pytest.raises(ProtocolError):
        check_response({"op": "ensure_up"}, Op.ENSURE_UP)


def test_conn_ids_unique() -> None:
    assert len({new_conn_id() for _ in range(100)}) == 100
