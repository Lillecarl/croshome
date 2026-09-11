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


class Hub:
    def __init__(self, ctx, runtime, state):
        os.makedirs(runtime, mode=0o700, exist_ok=True)
        os.makedirs(state, mode=0o700, exist_ok=True)
        self.router_addr = f"ipc://{runtime}/router.sock"
        self.xsub_addr = f"ipc://{runtime}/xsub.sock"
        self.xpub_addr = f"ipc://{runtime}/xpub.sock"
        self.mailbox = Mailbox(os.path.join(state, "mail.db"))

        # (name, session) -> {identity, last_seen, caps, online}
        self.registry = {}
        self.identity_map = {}  # identity bytes -> (name, session)
        self.pending = {}  # msg id -> (identity, expiry), for --reply-to routing

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
        m = {
            "v": P.V,
            "id": P.new_id(),
            "type": P.EVENT,
            "event": event,
            "ts": P.now(),
            **meta,
        }
        await self.events.send_multipart(
            [f"{P.EVENT_TOPIC}{event}".encode(), *P.encode(m)]
        )

    async def _reply(self, identity, request_meta, **extra):
        m = {
            "v": P.V,
            "id": P.new_id(),
            "type": P.ACK,
            "ok": True,
            "in_reply_to": request_meta.get("id"),
            "ts": P.now(),
            **extra,
        }
        await self.router.send_multipart([identity, *P.encode(m)])

    async def _failure(self, identity, request_meta, message):
        m = {
            "v": P.V,
            "id": P.new_id(),
            "type": P.ERROR,
            "ok": False,
            "error": message,
            "in_reply_to": request_meta.get("id") if request_meta else None,
            "ts": P.now(),
        }
        await self.router.send_multipart([identity, *P.encode(m)])

    def sender_addr(self, identity):
        entry = self.identity_map.get(identity)
        return P.address(*entry) if entry else identity.hex()

    async def _route(self, identity, meta, payload):
        try:
            await self.router.send_multipart([identity, *P.encode(meta, payload)])
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

    async def _deliver_to_session(self, key, meta, payload):
        name, session = key
        entry = self.registry.get(key)
        if entry and entry["online"]:
            if await self._route(entry["identity"], meta, payload):
                return "delivered"
            # The peer's connection died before the TTL caught it.
            await self._set_online(key, False)
        self.mailbox.put(
            meta["id"],
            name,
            session,
            meta.get("from"),
            meta.get("topic"),
            meta.get("reply_to"),
            meta["ts"],
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
                {
                    "v": P.V,
                    "id": msg_id,
                    "type": P.DELIVER,
                    "from": from_addr,
                    "topic": topic,
                    "reply_to": reply_to,
                    "ts": ts,
                },
                payload,
            )
            for msg_id, _, _, from_addr, topic, reply_to, ts, payload in rows
        ]

    async def _on_hello(self, identity, meta, payload):
        name = P.check_name(meta.get("name"), "name")
        session = P.check_name(meta.get("session"), "session")
        caps = [c for c in meta.get("caps", []) if isinstance(c, str)]
        key = (name, session)
        entry = self.registry.get(key)
        if entry and entry["identity"] != identity:
            self.identity_map.pop(entry["identity"], None)
        was_offline = entry is None or not entry["online"]
        self.identity_map[identity] = key
        self.registry[key] = {
            "identity": identity,
            "last_seen": P.now(),
            "caps": caps,
            "online": True,
        }
        if was_offline:
            await self.publish_event("session.up", name=name, session=session)
        delivers = self._drain_mailbox(name, session)
        for m, pl in delivers:
            await self.router.send_multipart([identity, *P.encode(m, pl)])
        await self._reply(identity, meta, status="hello", mailbox=len(delivers))

    async def _on_send(self, identity, meta, payload):
        msg_id = meta.get("id") or P.new_id()
        self.pending[msg_id] = (identity, P.now() + PENDING_TTL)
        out = {
            "v": P.V,
            "id": msg_id,
            "type": P.DELIVER,
            "from": self.sender_addr(identity),
            "topic": meta.get("topic"),
            "reply_to": meta.get("reply_to"),
            "ts": P.now(),
        }
        reply_to = meta.get("reply_to")
        if reply_to and not meta.get("to"):
            pend = self.pending.get(reply_to)
            if not pend:
                raise P.ProtocolError(f"unknown reply_to: {reply_to}")
            target, status = pend[0], ("delivered" if await self._route(
                pend[0], out, payload
            ) else "lost")
        else:
            name, session = self._parse_target(meta.get("to"))
            key = (name, session) if session else self._latest_live(name) or (name, None)
            status = await self._deliver_to_session(key, out, payload)
        await self._reply(identity, meta, status=status)

    async def _on_poll(self, identity, meta, payload):
        name = meta.get("name")
        session = meta.get("session")
        if name and session:
            P.check_name(name, "name")
            P.check_name(session, "session")
            key = (name, session)
            self.identity_map[identity] = key
            entry = self.registry.get(key)
            if entry:
                was_offline = not entry["online"]
                entry["identity"] = identity
                entry["last_seen"] = P.now()
                if was_offline:
                    await self._set_online(key, True)
        elif identity not in self.identity_map:
            raise P.ProtocolError("poll needs name and session, or a hello first")
        key = self.identity_map[identity]
        delivers = self._drain_mailbox(*key)
        for m, pl in delivers:
            await self.router.send_multipart([identity, *P.encode(m, pl)])
        await self._reply(identity, meta, status="drained", count=len(delivers))

    async def _on_broadcast(self, identity, meta, payload):
        # The hub publishes on the sender's behalf, so a broadcast needs no
        # second socket client-side and carries a hub-stamped `from`.
        topic = meta.get("topic") or "user"
        out = {
            "v": P.V,
            "id": meta.get("id") or P.new_id(),
            "type": P.BROADCAST,
            "from": self.sender_addr(identity),
            "topic": topic,
            "ts": P.now(),
        }
        await self.events.send_multipart([topic.encode(), *P.encode(out, payload)])
        await self._reply(identity, meta, status="broadcast", topic=topic)

    async def _on_who(self, identity, meta, payload):
        sessions = [
            {
                "name": k[0],
                "session": k[1],
                "online": v["online"],
                "last_seen": v["last_seen"],
                "caps": v["caps"],
            }
            for k, v in sorted(
                self.registry.items(), key=lambda kv: -kv[1]["last_seen"]
            )
        ]
        await self._reply(identity, meta, sessions=sessions)

    async def _on_bye(self, identity, meta, payload):
        name = meta.get("name")
        session = meta.get("session")
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
        await self._reply(identity, meta, status="bye")

    async def _handle(self, identity, meta, payload):
        t = meta.get("type")
        if t == P.PING:
            await self._reply(identity, meta, status="pong")
        elif t == P.HELLO:
            await self._on_hello(identity, meta, payload)
        elif t == P.SEND:
            await self._on_send(identity, meta, payload)
        elif t == P.POLL:
            await self._on_poll(identity, meta, payload)
        elif t == P.BROADCAST:
            await self._on_broadcast(identity, meta, payload)
        elif t == P.WHO:
            await self._on_who(identity, meta, payload)
        elif t == P.BYE:
            await self._on_bye(identity, meta, payload)
        else:
            raise P.ProtocolError(f"unknown type: {t!r}")

    async def router_loop(self):
        while True:
            frames = await self.router.recv_multipart()
            identity, frames = frames[0], frames[1:]
            key = self.identity_map.get(identity)
            if key:
                self.registry[key]["last_seen"] = P.now()
            meta = {}
            try:
                meta, payload = P.decode(frames)
                await self._handle(identity, meta, payload)
            except P.ProtocolError as e:
                await self._failure(identity, meta, str(e))

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
