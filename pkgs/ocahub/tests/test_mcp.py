import asyncio
import json

import pytest

from ocahub import mcp_server
from test_hub import Agent


@pytest.fixture
def identity(monkeypatch):
    monkeypatch.setenv("OCAHUB_NAME", "tester")
    monkeypatch.setenv("OCAHUB_SESSION", "t1")
    return "tester", "t1"


@pytest.mark.anyio
async def test_agents_list_empty(hub):
    assert json.loads(await mcp_server._agents_list()) == []


@pytest.mark.anyio
async def test_agents_list_shows_agent(hub):
    a = Agent(hub, "explore", "s1", caps=["read"])
    try:
        sessions = json.loads(await mcp_server._agents_list())
        entry = next(s for s in sessions if s["name"] == "explore")
        assert entry["session"] == "s1" and entry["asks"] == 0
    finally:
        a.close()


@pytest.mark.anyio
async def test_agent_send_tell(hub):
    a = Agent(hub, "worker", "w1")
    try:
        out = json.loads(
            await mcp_server._agent_send("worker@w1", "hi", "tell", False, 5, None)
        )
        assert out["status"] == "delivered"
        m, pl = await asyncio.to_thread(a.recv)
        assert m["kind"] == "tell" and pl == b"hi"
    finally:
        a.close()


@pytest.mark.anyio
async def test_agent_send_ask_and_reply(hub, identity):
    a = Agent(hub, "worker", "w1")
    try:
        # The tool call waits for the reply, and the loop it runs on
        # stays free while it waits -- the raw agent's blocking recv
        # happens in a thread, and the answer comes back over the
        # awaited task. A sync tool could not do both at once.
        task = asyncio.ensure_future(
            mcp_server._agent_send("worker@w1", "what?", "ask", True, 10, None)
        )
        m, _ = await asyncio.to_thread(a.recv)
        assert m["kind"] == "ask"
        rep = json.loads(await mcp_server._agent_reply(m["id"], "because"))
        assert rep["status"] == "delivered"
        res = json.loads(await asyncio.wait_for(task, 10))
        assert res["reply"]["payload"] == "because"
        assert res["reply"]["reply_to"] == m["id"]
    finally:
        a.close()


@pytest.mark.anyio
async def test_agent_reply_degrades_to_tell(hub):
    a = Agent(hub, "worker", "w1")
    try:
        rep = json.loads(await mcp_server._agent_reply("nosuch", "free", "worker@w1"))
        assert rep["status"] == "delivered"
        m, pl = await asyncio.to_thread(a.recv)
        assert m["kind"] == "tell" and pl == b"free"
    finally:
        a.close()


@pytest.mark.anyio
async def test_agent_inbox_drains_and_tracks_asks(hub, identity):
    c = hub.client()
    c.send(to="tester@t1", payload=b"mail")
    out = json.loads(await mcp_server._agent_inbox(0))
    assert [m["payload"] for m in out["messages"]] == ["mail"]
    asker = Agent(hub, "asker", "a1")
    try:
        asker.send({"kind": "ask", "to": "tester@t1"}, b"q")
        out = json.loads(await mcp_server._agent_inbox(0))
        assert len(out["unanswered_asks"]) == 1
        assert "agent_reply" in out["note"]
        ask_id = out["unanswered_asks"][0]["id"]
        rep = json.loads(await mcp_server._agent_reply(ask_id, "ans"))
        assert rep["status"] == "delivered"
        out = json.loads(await mcp_server._agent_inbox(0))
        assert out["unanswered_asks"] == []
        assert out["note"] is None
    finally:
        asker.close()


@pytest.mark.anyio
async def test_agent_send_rejects_reply_kind(hub):
    out = json.loads(await mcp_server._agent_send("x@y", "m", "reply", False, 5, None))
    assert "error" in out


@pytest.mark.anyio
async def test_agents_list_cwd_filter(hub, identity):
    a = Agent(hub, "worker", "w1", cwd="/home/lillecarl/Code/croshome")
    try:
        everyone = json.loads(await mcp_server._agents_list())
        assert any(s["name"] == "worker" for s in everyone)
        filtered = json.loads(await mcp_server._agents_list(cwd="croshome"))
        assert [s["name"] for s in filtered] == ["worker"]
        assert json.loads(await mcp_server._agents_list(cwd="/elsewhere")) == []
    finally:
        a.close()


@pytest.mark.anyio
async def test_agent_send_by_cwd(hub):
    a = Agent(hub, "worker", "w1", cwd="/repo")
    try:
        out = json.loads(
            await mcp_server._agent_send(None, "hi", "tell", False, 5, None, "/repo")
        )
        assert out["status"] == "delivered"
        _, pl = await asyncio.to_thread(a.recv)
        assert pl == b"hi"
    finally:
        a.close()
