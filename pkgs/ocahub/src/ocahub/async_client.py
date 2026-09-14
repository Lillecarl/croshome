"""The hub client for a host that runs an event loop.

The sync `Client` in cli.py is right for a one-shot CLI process: it
blocks, and nothing else needs the thread. An MCP server is the other
shape -- FastMCP dispatches `async def` tools on its own loop -- and a
blocking call in an async tool wedges that loop: every timeout and
every heartbeat stops with it, which the TUI checks measured the hard
way (see the commit that closed hub clients off the loop).

This twin keeps the wire identical -- the same frames, the same ACK
and DELIVER order, the same exceptions -- and never blocks: every
socket is `zmq.asyncio`, every call is awaited. LINGER is 0 on every
socket, so `close` drops what is unsent and returns.
"""

import os
import time

import zmq
import zmq.asyncio

from . import protocol as P
from .cli import HubError, Unreachable, WaitTimeout
from .daemon import runtime_dir


class AsyncClient:
    def __init__(self, runtime=None, timeout=None):
        self.runtime = runtime or runtime_dir()
        self.timeout = float(timeout or os.environ.get("OCAHUB_TIMEOUT") or 5.0)
        self.ctx = zmq.asyncio.Context()

    def dealer(self):
        d = self.ctx.socket(zmq.DEALER)
        d.setsockopt(zmq.LINGER, 0)
        d.connect(f"ipc://{self.runtime}/router.sock")
        return d

    async def request(self, dealer, msg, payload=b""):
        """Send one request, then read frames until the ACK, keeping DELIVERs.

        Mailbox drains arrive as DELIVERs before the ACK on the same pipe,
        so the caller sees them in order.
        """
        await dealer.send_multipart(P.encode(msg, payload))
        delivers = []
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = max(0.05, deadline - time.monotonic())
            dealer.setsockopt(zmq.RCVTIMEO, int(remaining * 1000))
            try:
                frames = await dealer.recv_multipart()
            except zmq.error.Again as e:
                raise Unreachable("hub did not answer in time") from e
            m, pl = P.decode(frames)
            if m.type == P.DELIVER:
                delivers.append((m, pl))
                continue
            if m.type == P.ACK:
                return m, delivers
            raise HubError(m.error)

    async def call(self, msg, payload=b""):
        d = self.dealer()
        try:
            return await self.request(d, msg, payload)
        finally:
            d.close(0)

    async def ping(self):
        return (await self.call(P.Ping()))[0]

    async def hello(self, name, session, caps=(), cwd=None, title=None):
        return await self.call(
            P.Hello(name=name, session=session, caps=list(caps), cwd=cwd, title=title)
        )

    async def who(self):
        return (await self.call(P.Who()))[0]

    async def asks(self, name, session):
        return (await self.call(P.Asks(name=name, session=session)))[0]

    async def send(
        self, to=None, topic=None, reply_to=None, kind=P.KIND_TELL, payload=b"", cwd=None
    ):
        return (
            await self.call(
                P.Send(
                    to=to,
                    topic=topic,
                    reply_to=reply_to,
                    kind=P.check_kind(kind),
                    cwd=cwd,
                ),
                payload,
            )
        )[0]

    async def send_wait(
        self,
        to=None,
        topic=None,
        reply_to=None,
        kind=P.KIND_TELL,
        payload=b"",
        wait=30.0,
        cwd=None,
    ):
        msg = P.Send(
            to=to, topic=topic, reply_to=reply_to, kind=P.check_kind(kind), cwd=cwd
        )
        d = self.dealer()
        try:
            ack, delivers = await self.request(d, msg, payload)
            if not ack.ok:
                raise HubError(ack.error or "unknown hub error")
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WaitTimeout("no reply arrived in time")
                d.setsockopt(zmq.RCVTIMEO, int(min(remaining, 0.25) * 1000))
                try:
                    m, pl = P.decode(await d.recv_multipart())
                except zmq.error.Again:
                    continue
                except P.ProtocolError:
                    continue
                if m.type == P.DELIVER and m.reply_to == msg.id:
                    return ack, m, pl
        finally:
            d.close(0)

    async def poll_wait(self, name, session, wait=30.0, cwd=None):
        d = self.dealer()
        try:
            ack, delivers = await self.request(
                d, P.Poll(name=name, session=session, cwd=cwd)
            )
            if delivers:
                return ack, *delivers[0]
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WaitTimeout("no message arrived in time")
                d.setsockopt(zmq.RCVTIMEO, int(min(remaining, 0.25) * 1000))
                try:
                    m, pl = P.decode(await d.recv_multipart())
                except zmq.error.Again:
                    continue
                except P.ProtocolError:
                    continue
                if m.type == P.DELIVER:
                    return ack, m, pl
        finally:
            d.close(0)

    def close(self):
        self.ctx.destroy(linger=0)
