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
ASKS = "asks"
PING = "ping"
PONG = "pong"
BYE = "bye"
WHO = "who"
ACK = "ack"
DELIVER = "deliver"
ERROR = "error"
EVENT = "event"

# Message kinds. ask asks for a reply the target owes before ending its
# turn (tracked in the hub's ask ledger); reply answers one and degrades
# to a plain tell when the ask is gone, so weak agents lose nothing.
KIND_TELL = "tell"
KIND_ASK = "ask"
KIND_REPLY = "reply"
KINDS = (KIND_TELL, KIND_ASK, KIND_REPLY)

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


def check_kind(value):
    if value is None:
        return KIND_TELL
    if value not in KINDS:
        raise ProtocolError(f"kind must be one of {KINDS}")
    return value


def check_cwd(value, field="cwd"):
    # Paths legitimately contain '@', spaces and anything else; only an
    # empty value is meaningless.
    if value is not None and (not isinstance(value, str) or not value.strip()):
        raise ProtocolError(f"{field} must be a non-empty string when given")
    return value


def cwd_match(registered, query):
    """Substring match either way, so full paths, basenames and a missing
    trailing slash all find their target."""
    registered, query = registered.rstrip("/"), query.rstrip("/")
    return query in registered or registered in query


def address(name, session):
    return f"{name}@{session}"
