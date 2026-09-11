"""The ocahub broker: one persistent process agents connect to.

anyio drives the loop (asyncio backend). Socket ownership is single-task by
direction: every ROUTER send happens on the router loop's task, every XPUB
send on the relay's. That sharing rule is what lets these sockets be reused
safely; adding a second sender on either needs a lock.
"""

import logging
import os
import signal
import sys

import anyio
import zmq
import zmq.asyncio

from . import protocol as P
from .store import Mailbox

log = logging.getLogger("ocahub")

SESSION_TTL = 120.0
MAILBOX_MAX_AGE = 7 * 24 * 3600.0
PENDING_TTL = 600.0
# Asks stay owed longer than replies may take to compose.
ASK_TTL = 1800.0
SWEEP_EVERY = 10.0


def runtime_dir():
    base = os.environ.get("OCAHUB_RUNTIME_DIR")
    if not base:
        base = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "ocahub"
        )
    return base


def state_dir():
    base = os.environ.get("OCAHUB_STATE_DIR")
    if not base:
        base = os.path.join(
            os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
            "ocahub",
        )
    return base


def _cwd_match(registered, query):
    return P.cwd_match(registered, query)


class Hub:
    def __init__(self, ctx, runtime, state):
        os.makedirs(runtime, mode=0o700, exist_ok=True)
        os.makedirs(state, mode=0o700, exist_ok=True)
        self.router_addr = f"ipc://{runtime}/router.sock"
        self.xsub_addr = f"ipc://{runtime}/xsub.sock"
        self.xpub_addr = f"ipc://{runtime}/xpub.sock"
        self.mailbox = Mailbox(os.path.join(state, "mail.db"))

        # (name, session) -> {identity, last_seen, caps, cwd, online}
        self.registry = {}
        self.identity_map = {}  # identity bytes -> (name, session)
        self.pending = {}  # msg id -> (identity, expiry), for --reply-to routing
        self.asks = {}  # msg id -> {target, from_identity, from, ts}, the ask ledger

        self.router = ctx.socket(zmq.ROUTER)
        # Sends to a vanished identity must fail loudly; without this they
        # queue silently and "delivered" would be a guess.
        self.router.setsockopt(zmq.ROUTER_MANDATORY, 1)
        self.router.bind(self.router_addr)

        self.xsub = ctx.socket(zmq.XSUB)
        self.xsub.bind(self.xsub_addr)
        self.xpub = ctx.socket(zmq.XPUB)
        self.xpub.bind(self.xpub_addr)
        # Hub events ride the same path agent broadcasts do: a PUB connected
        # to our XSUB, relayed to every subscriber.
        self.events = ctx.socket(zmq.PUB)
        self.events.connect(self.xsub_addr)

    async def publish_event(self, event, **meta):
        msg = P.EventMsg(event=event, **meta)
        await self.events.send_multipart([f"{P.EVENT_TOPIC}{event}".encode(), *P.encode(msg)])

    async def _ack(self, identity, request, **fields):
        msg = P.Ack(ok=True, in_reply_to=request.id, **fields)
        await self.router.send_multipart([identity, *P.encode(msg)])

    async def _failure(self, identity, request, message):
        msg = P.ErrorMsg(
            error=message,
            in_reply_to=request.id if isinstance(request, P.Meta) else None,
        )
        await self.router.send_multipart([identity, *P.encode(msg)])

    def sender_addr(self, identity):
        entry = self.identity_map.get(identity)
        return P.address(*entry) if entry else identity.hex()

    async def _route(self, identity, deliver, payload):
        try:
            await self.router.send_multipart([identity, *P.encode(deliver, payload)])
            return True
        except zmq.ZMQError as e:
            log.debug("route to %s failed: %s", identity.hex(), e)
            return False

    async def _set_online(self, key, online):
        entry = self.registry.get(key)
        if entry and entry["online"] != online:
            entry["online"] = online
            await self.publish_event(
                "session.up" if online else "session.down",
                name=key[0],
                session=key[1],
            )

    async def _deliver_to_session(self, key, deliver, payload):
        name, session = key
        entry = self.registry.get(key)
        if entry and entry["online"]:
            if await self._route(entry["identity"], deliver, payload):
                return "delivered"
            # The peer's connection died before the TTL caught it.
            await self._set_online(key, False)
        self.mailbox.put(
            deliver.id,
            name,
            session,
            deliver.kind,
            deliver.sender,
            deliver.topic,
            deliver.reply_to,
            deliver.ts,
            payload,
        )
        return "queued"

    def _latest_live(self, name):
        live = [
            (v["last_seen"], k)
            for k, v in self.registry.items()
            if k[0] == name and v["online"]
        ]
        return max(live)[1] if live else None

    def _latest_live_by_cwd(self, cwd):
        live = [
            (v["last_seen"], k)
            for k, v in self.registry.items()
            if v["online"] and v.get("cwd") and _cwd_match(v["cwd"], cwd)
        ]
        return max(live)[1] if live else None

    @staticmethod
    def _parse_target(to):
        if not isinstance(to, str) or not to:
            raise P.ProtocolError("send needs 'to' (or a 'reply_to')")
        if "@" in to:
            name, _, session = to.rpartition("@")
            P.check_name(name, "name")
            P.check_name(session, "session")
            return name, session
        return P.check_name(to, "name"), None

    def _drain_mailbox(self, name, session):
        rows = self.mailbox.take(name, session)
        return [
            (
                P.Deliver(
                    id=msg_id,
                    kind=kind,
                    sender=from_addr,
                    topic=topic,
                    reply_to=reply_to,
                    ts=ts,
                ),
                payload,
            )
            for msg_id, _, _, kind, from_addr, topic, reply_to, ts, payload in rows
        ]

    async def _on_hello(self, identity, msg, payload):
        name = P.check_name(msg.name, "name")
        session = P.check_name(msg.session, "session")
        caps = [c for c in (msg.caps or ()) if isinstance(c, str)]
        key = (name, session)
        entry = self.registry.get(key)
        if entry and entry["identity"] != identity:
            self.identity_map.pop(entry["identity"], None)
        was_offline = entry is None or not entry["online"]
        self.identity_map[identity] = key
        # A re-hello without cwd keeps the one on record.
        cwd = P.check_cwd(msg.cwd) or (entry.get("cwd") if entry else None)
        self.registry[key] = {
            "identity": identity,
            "last_seen": P.now(),
            "caps": caps,
            "online": True,
            "cwd": cwd,
        }
        if was_offline:
            await self.publish_event("session.up", name=name, session=session)
        delivers = self._drain_mailbox(name, session)
        for m, pl in delivers:
            await self.router.send_multipart([identity, *P.encode(m, pl)])
        await self._ack(identity, msg, status="hello", mailbox=len(delivers))

    async def _on_send(self, identity, msg, payload):
        kind = P.check_kind(msg.kind)
        msg_id = msg.id
        self.pending[msg_id] = (identity, P.now() + PENDING_TTL)
        out = P.Deliver(
            id=msg_id,
            kind=kind,
            sender=self.sender_addr(identity),
            topic=msg.topic,
            reply_to=msg.reply_to,
        )
        reply_to = msg.reply_to
        if kind == P.KIND_REPLY and reply_to:
            # Forgiving: a reply with no live ask rides through as a tell.
            ask = self.asks.pop(reply_to, None)
            out.kind = P.KIND_REPLY if ask else P.KIND_TELL
            target = (ask or {}).get("from_identity")
            if target is None:
                target = self.pending.get(reply_to, (None,))[0]
            if target is not None and await self._route(target, out, payload):
                status = "delivered"
            elif msg.to:
                name, session = self._parse_target(msg.to)
                key = (name, session) if session else self._latest_live(name) or (name, None)
                status = await self._deliver_to_session(key, out, payload)
            else:
                raise P.ProtocolError("reply target is gone; pass 'to'")
        elif reply_to and not msg.to:
            pend = self.pending.get(reply_to)
            if not pend:
                raise P.ProtocolError(f"unknown reply_to: {reply_to}")
            status = "delivered" if await self._route(pend[0], out, payload) else "lost"
        else:
            if msg.to:
                name, session = self._parse_target(msg.to)
                key = (name, session) if session else self._latest_live(name) or (name, None)
            elif msg.cwd:
                key = self._latest_live_by_cwd(msg.cwd)
                if key is None:
                    raise P.ProtocolError(
                        f"no online session with cwd matching {msg.cwd}"
                    )
            else:
                raise P.ProtocolError("send needs 'to' or 'cwd' (or a 'reply_to')")
            status = await self._deliver_to_session(key, out, payload)
            if kind == P.KIND_ASK:
                self.asks[msg_id] = {
                    "target": key,
                    "from_identity": identity,
                    "from": out.sender,
                    "ts": out.ts,
                }
        await self._ack(identity, msg, status=status, kind=kind)

    async def _resolve_session(self, identity, msg):
        """Key for this caller: explicit name/session, else the hello mapping.

        An explicit key re-binds the registry entry's socket to this caller,
        which is how a fresh process attaches to an existing session. A key
        with no entry is created, so a poll-only session is discoverable.
        """
        name = msg.name
        session = msg.session
        if name and session:
            P.check_name(name, "name")
            P.check_name(session, "session")
            key = (name, session)
            self.identity_map[identity] = key
            entry = self.registry.get(key)
            if entry is None:
                self.registry[key] = {
                    "identity": identity,
                    "last_seen": P.now(),
                    "caps": [],
                    "online": True,
                    "cwd": None,
                }
                await self.publish_event("session.up", name=name, session=session)
            else:
                was_offline = not entry["online"]
                entry["identity"] = identity
                entry["last_seen"] = P.now()
                if was_offline:
                    await self._set_online(key, True)
            cwd = P.check_cwd(msg.cwd)
            if cwd:
                entry = self.registry[key]
                entry["cwd"] = cwd
        elif identity not in self.identity_map:
            raise P.ProtocolError("needs name and session, or a hello first")
        return self.identity_map[identity]

    async def _on_poll(self, identity, msg, payload):
        key = await self._resolve_session(identity, msg)
        delivers = self._drain_mailbox(*key)
        for m, pl in delivers:
            await self.router.send_multipart([identity, *P.encode(m, pl)])
        await self._ack(identity, msg, status="drained", count=len(delivers))

    async def _on_asks(self, identity, msg, payload):
        key = await self._resolve_session(identity, msg)
        name, _ = key
        items = [
            {"id": ask_id, "from": a["from"], "ts": a["ts"]}
            for ask_id, a in sorted(self.asks.items(), key=lambda kv: kv[1]["ts"])
            if a["target"] == key or a["target"] == (name, None)
        ]
        await self._ack(identity, msg, asks=items)

    def _ask_count(self, key):
        name, _ = key
        return sum(
            1
            for a in self.asks.values()
            if a["target"] == key or a["target"] == (name, None)
        )

    async def _on_who(self, identity, msg, payload):
        sessions = [
            {
                "name": k[0],
                "session": k[1],
                "online": v["online"],
                "last_seen": v["last_seen"],
                "caps": v["caps"],
                "cwd": v.get("cwd"),
                "asks": self._ask_count(k),
            }
            for k, v in sorted(
                self.registry.items(), key=lambda kv: -kv[1]["last_seen"]
            )
        ]
        await self._ack(identity, msg, sessions=sessions)

    async def _on_bye(self, identity, msg, payload):
        name = msg.name
        session = msg.session
        key = None
        if name and session:
            P.check_name(name, "name")
            P.check_name(session, "session")
            key = (name, session)
            entry = self.registry.get(key)
            if entry:
                self.identity_map.pop(entry["identity"], None)
        else:
            key = self.identity_map.pop(identity, None)
            entry = self.registry.get(key) if key else None
        if key and entry:
            entry["online"] = False
            await self.publish_event("session.down", name=key[0], session=key[1])
        await self._ack(identity, msg, status="bye")

    async def _handle(self, identity, msg, payload):
        t = msg.type
        if t == P.PING:
            await self._ack(identity, msg, status="pong")
        elif t == P.HELLO:
            await self._on_hello(identity, msg, payload)
        elif t == P.SEND:
            await self._on_send(identity, msg, payload)
        elif t == P.POLL:
            await self._on_poll(identity, msg, payload)
        elif t == P.ASKS:
            await self._on_asks(identity, msg, payload)
        elif t == P.BROADCAST:
            # The hub publishes on the sender's behalf, so a broadcast needs
            # no second socket client-side and carries a hub-stamped sender.
            topic = msg.topic or "user"
            out = P.Broadcast(
                id=msg.id,
                sender=self.sender_addr(identity),
                topic=topic,
            )
            await self.events.send_multipart([topic.encode(), *P.encode(out, payload)])
            await self._ack(identity, msg, status="broadcast", topic=topic)
        elif t == P.WHO:
            await self._on_who(identity, msg, payload)
        elif t == P.BYE:
            await self._on_bye(identity, msg, payload)
        else:
            raise P.ProtocolError(f"unknown type: {t!r}")

    async def router_loop(self):
        while True:
            frames = await self.router.recv_multipart()
            identity, frames = frames[0], frames[1:]
            key = self.identity_map.get(identity)
            if key:
                self.registry[key]["last_seen"] = P.now()
            msg = {}
            try:
                msg, payload = P.decode(frames)
                await self._handle(identity, msg, payload)
            except P.ProtocolError as e:
                await self._failure(identity, msg, str(e))
            except Exception:
                # One bad handler must not kill the broker; the request
                # still gets an answer.
                log.exception("handler failed for %r", getattr(msg, "type", msg))
                try:
                    await self._failure(identity, msg, "internal hub error")
                except Exception:
                    pass

    async def relay_loop(self):
        # Data half of zmq_proxy, hand-rolled: agent PUBs and the hub's event
        # PUB connect to XSUB; everything received there is fanout traffic.
        while True:
            frames = await self.xsub.recv_multipart()
            await self.xpub.send_multipart(frames)

    async def control_loop(self):
        # Subscription half of zmq_proxy: XPUB emits one control frame per
        # subscriber subscribe/unsubscribe; XSUB forwards it to publishers.
        while True:
            frames = await self.xpub.recv_multipart()
            await self.xsub.send_multipart(frames)

    async def sweeper(self):
        while True:
            await anyio.sleep(SWEEP_EVERY)
            now = P.now()
            for key, entry in list(self.registry.items()):
                if entry["online"] and now - entry["last_seen"] > SESSION_TTL:
                    await self._set_online(key, False)
            self.mailbox.prune(MAILBOX_MAX_AGE, now)
            expired = [m for m, (_, exp) in self.pending.items() if exp < now]
            for msg_id in expired:
                del self.pending[msg_id]
            stale_asks = [m for m, a in self.asks.items() if now - a["ts"] > ASK_TTL]
            for msg_id in stale_asks:
                del self.asks[msg_id]


async def serve(runtime=None, state=None):
    ctx = zmq.asyncio.Context()
    hub = Hub(ctx, runtime or runtime_dir(), state or state_dir())
    try:
        async with anyio.create_task_group() as tg:
            tg.start_soon(hub.router_loop)
            tg.start_soon(hub.relay_loop)
            tg.start_soon(hub.control_loop)
            tg.start_soon(hub.sweeper)
            with anyio.open_signal_receiver(signal.SIGINT, signal.SIGTERM) as sigs:
                async for _ in sigs:
                    tg.cancel_scope.cancel()
    finally:
        ctx.destroy(linger=0)


def main():
    logging.basicConfig(
        level=os.environ.get("OCAHUB_LOG", "INFO").upper(),
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    anyio.run(serve)


if __name__ == "__main__":
    main()
