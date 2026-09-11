"""Envelope framing. Every control message is two ZMQ frames: meta, payload.

meta is a JSON object: v, id, type, ts, plus per-verb fields. payload is raw
bytes reserved for user data; the hub never inspects it.
"""

import json
import time
import uuid

V = 1

HELLO = "hello"
SEND = "send"
BROADCAST = "broadcast"
POLL = "poll"
PING = "ping"
PONG = "pong"
BYE = "bye"
WHO = "who"
ACK = "ack"
DELIVER = "deliver"
ERROR = "error"
EVENT = "event"

# Namespace for hub-generated events on the pub/sub proxy; agent topics must
# not start with this or a `sub ""` client cannot tell them apart.
EVENT_TOPIC = "ocahub/"


class ProtocolError(ValueError):
    pass


def now() -> float:
    return time.time()


def new_id() -> str:
    return uuid.uuid4().hex


def encode(meta: dict, payload: bytes = b"") -> list:
    return [json.dumps(meta, separators=(",", ":")).encode(), payload]


def decode(frames) -> tuple:
    if len(frames) != 2:
        raise ProtocolError(f"expected 2 frames, got {len(frames)}")
    try:
        meta = json.loads(frames[0])
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ProtocolError(f"meta is not JSON: {e}") from e
    if not isinstance(meta, dict):
        raise ProtocolError("meta is not a JSON object")
    return meta, frames[1]


def check_name(value, field):
    if not isinstance(value, str) or not value:
        raise ProtocolError(f"{field} must be a non-empty string")
    if "@" in value or any(c.isspace() for c in value):
        raise ProtocolError(f"{field} must not contain '@' or whitespace")
    return value


def address(name, session):
    return f"{name}@{session}"
