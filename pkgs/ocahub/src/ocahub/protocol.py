"""Envelope framing. Every control message is two ZMQ frames: meta, payload.

meta is one of the dataclasses below, serialized to a single JSON frame;
payload is raw bytes reserved for user data, which the hub never inspects.
The dataclasses are the schema: parsing rejects unknown fields and missing
required ones instead of letting them ride along, and a wrong protocol
version is refused outright.
"""

import dataclasses
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import ClassVar

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


def check_name(value, field_name):
    if not isinstance(value, str) or not value:
        raise ProtocolError(f"{field_name} must be a non-empty string")
    if "@" in value or any(c.isspace() for c in value):
        raise ProtocolError(f"{field_name} must not contain '@' or whitespace")
    return value


def check_kind(value):
    if value is None:
        return KIND_TELL
    if value not in KINDS:
        raise ProtocolError(f"kind must be one of {KINDS}")
    return value


def check_cwd(value, field_name="cwd"):
    # Paths legitimately contain '@', spaces and anything else; only an
    # empty value is meaningless.
    if value is not None and (not isinstance(value, str) or not value.strip()):
        raise ProtocolError(f"{field_name} must be a non-empty string when given")
    return value


def cwd_match(registered, query):
    """Substring match either way, so full paths, basenames and a missing
    trailing slash all find their target."""
    registered, query = registered.rstrip("/"), query.rstrip("/")
    return query in registered or registered in query


def address(name, session):
    return f"{name}@{session}"


# `from` is a Python keyword, so the field is `sender` on the wire.
_WIRE_ALIASES = {"sender": "from"}


@dataclass
class Meta:
    # kw_only: required subclass fields cannot follow defaulted base fields.
    v: int = field(default=V, kw_only=True)
    id: str = field(default_factory=new_id, kw_only=True)
    ts: float = field(default_factory=now, kw_only=True)

    TYPE: ClassVar[str] = ""

    @property
    def type(self) -> str:
        return self.TYPE

    def to_dict(self) -> dict:
        d = dataclasses.asdict(self)
        d["type"] = self.TYPE
        for py, wire in _WIRE_ALIASES.items():
            if py in d:
                d[wire] = d.pop(py)
        return {k: v for k, v in d.items() if v is not None}

    def encode(self, payload: bytes = b"") -> list:
        return [json.dumps(self.to_dict(), separators=(",", ":")).encode(), payload]

    def get(self, key, default=None):
        if key == "type":
            return self.TYPE
        if key == "from":
            return getattr(self, "sender", default)
        return getattr(self, key, default)

    def __getitem__(self, key):
        try:
            if key == "type":
                return self.TYPE
            if key == "from":
                return self.sender
            return getattr(self, key)
        except AttributeError:
            raise KeyError(key) from None


@dataclass
class Hello(Meta):
    TYPE: ClassVar[str] = HELLO

    name: str
    session: str
    caps: list = ()
    cwd: str | None = None
    # The human-facing session title (what /rename sets in opencode). Free
    # text; the hub stores it as-is and who() reports it.
    title: str | None = None


@dataclass
class Send(Meta):
    TYPE: ClassVar[str] = SEND

    kind: str = KIND_TELL
    to: str | None = None
    cwd: str | None = None
    topic: str | None = None
    reply_to: str | None = None


@dataclass
class Poll(Meta):
    TYPE: ClassVar[str] = POLL

    name: str | None = None
    session: str | None = None
    cwd: str | None = None


@dataclass
class Asks(Meta):
    TYPE: ClassVar[str] = ASKS

    name: str | None = None
    session: str | None = None
    cwd: str | None = None


@dataclass
class Bye(Meta):
    TYPE: ClassVar[str] = BYE

    name: str | None = None
    session: str | None = None


@dataclass
class Ping(Meta):
    TYPE: ClassVar[str] = PING


@dataclass
class Who(Meta):
    TYPE: ClassVar[str] = WHO


@dataclass
class Ack(Meta):
    TYPE: ClassVar[str] = ACK

    ok: bool = True
    in_reply_to: str | None = None
    status: str | None = None
    kind: str | None = None
    topic: str | None = None
    mailbox: int | None = None
    count: int | None = None
    sessions: list | None = None
    asks: list | None = None
    note: str | None = None


@dataclass
class ErrorMsg(Meta):
    TYPE: ClassVar[str] = ERROR

    error: str
    ok: bool = False
    in_reply_to: str | None = None


@dataclass
class Deliver(Meta):
    TYPE: ClassVar[str] = DELIVER

    kind: str = KIND_TELL
    sender: str = ""
    topic: str | None = None
    reply_to: str | None = None


@dataclass
class Broadcast(Meta):
    TYPE: ClassVar[str] = BROADCAST

    sender: str = ""
    topic: str = "user"


@dataclass
class EventMsg(Meta):
    TYPE: ClassVar[str] = EVENT

    event: str = ""
    name: str | None = None
    session: str | None = None


TYPES: dict[str, type] = {}
for _cls in (
    Hello,
    Send,
    Poll,
    Asks,
    Bye,
    Ping,
    Who,
    Ack,
    ErrorMsg,
    Deliver,
    Broadcast,
    EventMsg,
):
    TYPES[_cls.TYPE] = _cls

_BASE_FIELDS = ("v", "id", "ts", "type")


def parse(meta: dict) -> Meta:
    t = meta.get("type")
    cls = TYPES.get(t)
    if cls is None:
        raise ProtocolError(f"unknown message type: {t!r}")
    version = meta.get("v", V)
    if version != V:
        raise ProtocolError(f"unsupported protocol version: {version!r}")
    by_wire = {wire: py for py, wire in _WIRE_ALIASES.items()}
    names = {f.name for f in dataclasses.fields(cls)}
    kwargs: dict = {}
    unknown = []
    for k, v in meta.items():
        if k in _BASE_FIELDS:
            continue
        k = by_wire.get(k, k)
        if k in names:
            kwargs[k] = v
        else:
            unknown.append(k)
    if unknown:
        raise ProtocolError(f"{t}: unknown field(s): {sorted(unknown)}")
    try:
        msg = cls(**kwargs)
    except TypeError as e:
        raise ProtocolError(f"{t}: {e}") from e
    # The wire's identity: a parsed message keeps the id and ts it arrived
    # with, or reply_to correlation and mailbox ordering fall apart.
    if "id" in meta:
        msg.id = meta["id"]
    if "ts" in meta:
        msg.ts = meta["ts"]
    return msg


def encode(msg, payload: bytes = b"") -> list:
    if isinstance(msg, Meta):
        return msg.encode(payload)
    if isinstance(msg, dict):
        return [json.dumps(msg, separators=(",", ":")).encode(), payload]
    raise ProtocolError(f"encode needs a Meta or a dict, got {type(msg).__name__}")


def decode(frames) -> tuple:
    if len(frames) != 2:
        raise ProtocolError(f"expected 2 frames, got {len(frames)}")
    try:
        raw = json.loads(frames[0])
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ProtocolError(f"meta is not JSON: {e}") from e
    if not isinstance(raw, dict):
        raise ProtocolError("meta is not a JSON object")
    return parse(raw), frames[1]
