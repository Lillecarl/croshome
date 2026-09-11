import threading
import time

import zmq

from ocahub import protocol as P
from ocahub.cli import Client, HubError, Unreachable, WaitTimeout
from conftest import Hub


class Agent:
    """A raw-socket agent speaking the wire protocol directly."""

    def __init__(self, hub, name, session, caps=(), cwd=None):
        self.name, self.session = name, session
        self.ctx = zmq.Context()
        self.dealer = self.ctx.socket(zmq.DEALER)
        self.dealer.setsockopt(zmq.LINGER, 0)
        self.dealer.setsockopt(zmq.RCVTIMEO, 10000)
        self.dealer.connect(f"ipc://{hub.runtime}/router.sock")
        hello = {"type": P.HELLO, "name": name, "session": session, "caps": list(caps)}
        if cwd:
            hello["cwd"] = cwd
        _, self.hello_delivers = self._rpc(hello)

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


def test_ask_reply_roundtrip(hub):
    a = Agent(hub, "asker", "a1")
    b = Agent(hub, "worker", "w1")
    try:
        a.send({"kind": P.KIND_ASK, "to": "worker@w1"}, b"what?")
        m, pl = b.recv()
        assert m["kind"] == P.KIND_ASK and pl == b"what?"
        ask_id = m["id"]
        who = hub.client().who()["sessions"]
        assert next(s for s in who if s["name"] == "worker")["asks"] == 1
        b.send({"kind": P.KIND_REPLY, "reply_to": ask_id}, b"so")
        rm, rpl = a.recv()
        assert rm["kind"] == P.KIND_REPLY and rm["reply_to"] == ask_id and rpl == b"so"
        who = hub.client().who()["sessions"]
        assert next(s for s in who if s["name"] == "worker")["asks"] == 0
    finally:
        a.close()
        b.close()


def test_reply_degrades_to_tell_without_ask(hub):
    a = Agent(hub, "asker", "a1")
    b = Agent(hub, "worker", "w1")
    try:
        # No ask was ever sent; the reply must still land, as a tell.
        b.send({"kind": P.KIND_REPLY, "reply_to": "nosuchid", "to": "asker@a1"}, b"late")
        m, pl = a.recv()
        assert m["kind"] == P.KIND_TELL and pl == b"late"
    finally:
        a.close()
        b.close()


def test_reply_survives_expired_ask_via_pending(hub):
    # A tell (not an ask) opens a pending entry; a reply_to against it
    # routes back as a tell because no ask was owed.
    a = Agent(hub, "asker", "a1")
    b = Agent(hub, "worker", "w1")
    try:
        a.send({"to": "worker@w1"}, b"fyi")
        m, _ = b.recv()
        b.send({"kind": P.KIND_REPLY, "reply_to": m["id"]}, b"got it")
        rm, rpl = a.recv()
        assert rm["kind"] == P.KIND_TELL and rpl == b"got it"
    finally:
        a.close()
        b.close()


def test_reply_without_target_after_ask_expired(hub):
    a = Agent(hub, "asker", "a1")
    try:
        c = hub.client()
        try:
            c.send(kind=P.KIND_REPLY, reply_to="vanished", payload=b"orphan")
            raise AssertionError("expected HubError")
        except HubError as e:
            assert "reply target is gone" in str(e)
    finally:
        a.close()


def test_asks_verb_lists_open_asks(hub):
    a = Agent(hub, "asker", "a1")
    b = Agent(hub, "worker", "w1")
    try:
        a.send({"kind": P.KIND_ASK, "to": "worker@w1"}, b"q1")
        a.send({"kind": P.KIND_ASK, "to": "worker"}, b"q2")
        ask_ack, _ = b._rpc({"type": P.ASKS, "name": "worker", "session": "w1"})
        assert [i["from"] for i in ask_ack["asks"]] == ["asker@a1", "asker@a1"]
        assert all(i["id"] for i in ask_ack["asks"])
    finally:
        a.close()
        b.close()


def test_mailbox_migrates_v0_store(tmp_path):
    # A v0 store has no `kind` column; the migration appends it last, and a
    # positional INSERT then feeds `ts` a NULL. This is the shape that
    # crashed the deployed hub.
    import sqlite3

    from ocahub.store import Mailbox

    path = tmp_path / "mail.db"
    db = sqlite3.connect(path)
    db.execute(
        """CREATE TABLE mailbox (
        msg_id TEXT PRIMARY KEY, to_name TEXT NOT NULL, to_session TEXT,
        from_addr TEXT, topic TEXT, reply_to TEXT, ts REAL NOT NULL,
        payload BLOB NOT NULL)"""
    )
    db.execute("INSERT INTO mailbox VALUES ('old', 'late', NULL, 'a', NULL, NULL, 1.0, x'78')")
    db.commit()
    db.close()

    box = Mailbox(path)
    box.put("new", "late", "l1", "ask", "a", None, None, 2.0, b"y")
    # take() orders by ts: the v0 row first, the new ask second.
    rows = box.take("late", "l1")
    assert [r[0] for r in rows] == ["old", "new"]
    assert rows[0][8] == b"x" and rows[1][3] == "ask" and rows[1][8] == b"y"


def test_ask_to_offline_queues_with_kind(hub):
    c = hub.client()
    ack = c.send(to="late", kind=P.KIND_ASK, payload=b"owed")
    assert ack["status"] == "queued"
    a = Agent(hub, "late", "l1")
    try:
        assert len(a.hello_delivers) == 1
        m, pl = a.hello_delivers[0]
        assert m["kind"] == P.KIND_ASK and pl == b"owed"
    finally:
        a.close()


def test_cwd_registered_and_targeted(hub):
    a = Agent(hub, "worker", "w1", cwd="/home/x/proj")
    try:
        who = hub.client().who()["sessions"]
        assert next(s for s in who if s["name"] == "worker")["cwd"] == "/home/x/proj"
        ack = hub.client().send(cwd="/home/x/proj", payload=b"hi")
        assert ack["status"] == "delivered"
        _, pl = a.recv()
        assert pl == b"hi"
    finally:
        a.close()


def test_send_by_cwd_prefix_matches(hub):
    a = Agent(hub, "worker", "w1", cwd="/home/x/proj/sub")
    try:
        ack = hub.client().send(cwd="/home/x/proj", payload=b"deep")
        assert ack["status"] == "delivered"
    finally:
        a.close()


def test_send_by_cwd_without_online_fails(hub):
    a = Agent(hub, "worker", "w1", cwd="/home/x/proj")
    try:
        c = hub.client()
        try:
            c.send(cwd="/nowhere", payload=b"x")
            raise AssertionError("expected HubError")
        except HubError as e:
            assert "no online session" in str(e)
    finally:
        a.close()


def test_poll_attach_creates_registry_entry_with_cwd(hub):
    c = hub.client()
    c.call(
        {
            "v": P.V,
            "id": P.new_id(),
            "type": P.POLL,
            "name": "phantom",
            "session": "p9",
            "cwd": "/w/p",
            "ts": P.now(),
        }
    )
    who = c.who()["sessions"]
    entry = next(s for s in who if s["name"] == "phantom")
    assert entry["online"] and entry["cwd"] == "/w/p"
