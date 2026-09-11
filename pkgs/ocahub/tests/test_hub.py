import threading
import time

import zmq

from ocahub import protocol as P
from ocahub.cli import Unreachable, WaitTimeout
from ocahub.cli import Client
from conftest import Hub


class Agent:
    """A raw-socket agent speaking the wire protocol directly."""

    def __init__(self, hub, name, session, caps=()):
        self.name, self.session = name, session
        self.ctx = zmq.Context()
        self.dealer = self.ctx.socket(zmq.DEALER)
        self.dealer.setsockopt(zmq.LINGER, 0)
        self.dealer.setsockopt(zmq.RCVTIMEO, 10000)
        self.dealer.connect(f"ipc://{hub.runtime}/router.sock")
        _, self.hello_delivers = self._rpc(
            {"type": P.HELLO, "name": name, "session": session, "caps": list(caps)}
        )

    def _rpc(self, meta, payload=b""):
        self.dealer.send_multipart(P.encode(meta, payload))
        delivers = []
        while True:
            m, pl = P.decode(self.dealer.recv_multipart())
            if m["type"] == P.DELIVER:
                delivers.append((m, pl))
                continue
            assert m.get("ok"), m
            return m, delivers

    def recv(self):
        m, pl = P.decode(self.dealer.recv_multipart())
        assert m["type"] == P.DELIVER, m
        return m, pl

    def send(self, extra=None, payload=b""):
        return self._rpc({"type": P.SEND, "id": P.new_id(), **(extra or {})}, payload)

    def bye(self):
        return self._rpc({"type": P.BYE, "name": self.name, "session": self.session})

    def close(self):
        self.ctx.destroy(linger=0)


def test_ping(hub):
    m = hub.client().ping()
    assert m["ok"] and m["status"] == "pong"


def test_hub_unreachable(tmp_path):
    c = Client(runtime=str(tmp_path / "nothing"), timeout=0.5)
    try:
        c.ping()
        raise AssertionError("expected Unreachable")
    except Unreachable:
        pass
    finally:
        c.close()


def test_hello_and_who(hub):
    a = Agent(hub, "explore", "s1", caps=["read"])
    try:
        sessions = hub.client().who()["sessions"]
        entry = next(s for s in sessions if s["name"] == "explore")
        assert entry["session"] == "s1"
        assert entry["online"] and entry["caps"] == ["read"]
    finally:
        a.close()


def test_bye_goes_offline(hub):
    a = Agent(hub, "explore", "s1")
    a.bye()
    a.close()
    sessions = hub.client().who()["sessions"]
    assert not next(s for s in sessions if s["name"] == "explore")["online"]


def test_send_online_and_reply(hub):
    b = Agent(hub, "worker", "w1")
    try:
        out = {}

        def ask():
            c = hub.client()
            try:
                out["reply"] = c.send_wait(to="worker@w1", payload=b"hello", wait=10)
            except Exception as e:
                out["error"] = e

        th = threading.Thread(target=ask)
        th.start()
        m, pl = b.recv()
        assert pl == b"hello" and m["type"] == P.DELIVER
        b.send({"reply_to": m["id"]}, b"hi back")
        th.join(15)
        assert "error" not in out, out["error"]
        ack, rm, rpl = out["reply"]
        assert ack["status"] == "delivered"
        assert rm["reply_to"] == m["id"] and rpl == b"hi back"
    finally:
        b.close()


def test_send_to_absent_name_queues(hub):
    ack = hub.client().send(to="late", payload=b"queued")
    assert ack["status"] == "queued"
    a = Agent(hub, "late", "l1")
    try:
        assert len(a.hello_delivers) == 1
        m, pl = a.hello_delivers[0]
        assert pl == b"queued" and m["from"]  # stamped by the hub
    finally:
        a.close()


def test_mailbox_survives_restart(hub):
    hub.client().send(to="late@l1", payload=b"kept")
    hub.stop()
    h2 = Hub(hub.runtime, hub.state)
    try:
        a = Agent(h2, "late", "l1")
        try:
            assert len(a.hello_delivers) == 1
            _, pl = a.hello_delivers[0]
            assert pl == b"kept"
        finally:
            a.close()
    finally:
        h2.stop()


def test_broadcast_and_sub(hub):
    sub = hub.subscribe("news")
    try:
        time.sleep(0.5)  # slow joiner: let the subscription propagate
        ack = hub.client().broadcast(topic="news", payload=b"boom")
        assert ack["ok"]
        frames = sub.recv_multipart()
        assert frames[0] == b"news"
        m, pl = P.decode(frames[1:])
        assert m["type"] == P.BROADCAST and pl == b"boom"
    finally:
        sub.close(0)


def test_session_events(hub):
    sub = hub.subscribe(P.EVENT_TOPIC)
    try:
        time.sleep(0.5)
        a = Agent(hub, "x", "s1")
        up = sub.recv_multipart()
        assert up[0].startswith(b"ocahub/session.up")
        a.bye()
        down = sub.recv_multipart()
        assert down[0].startswith(b"ocahub/session.down")
        a.close()
    finally:
        sub.close(0)


def test_poll_drains_and_waits(hub):
    c = hub.client()
    c.send(to="p@p1", payload=b"first")
    # A second message queued while the poller is attached must be visible
    # through --wait semantics, exercised via the library here.
    ack, m, pl = c.poll_wait("p", "p1", wait=5)
    assert ack["status"] == "drained" and pl == b"first"
    try:
        c.poll_wait("p", "p1", wait=0.5)
        raise AssertionError("expected WaitTimeout")
    except WaitTimeout:
        pass
