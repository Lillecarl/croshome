"""MCP adapter over ocahub.

Tools for an agent session running inside opencode (or any MCP client):
list the directory, tell/ask/reply, and drain the inbox. The server is
stateless: each call opens a short-lived dealer, and identity comes from
OCAHUB_NAME/OCAHUB_SESSION with a per-process session id default, so
concurrent agent sessions stay apart.

Every tool is `async def` and every hub call is awaited: FastMCP
dispatches tools on its own loop, and a blocking call in an async tool
wedged that loop -- the TUI checks measured the hang. The sync `Client`
and its blocking `close` belong to one-shot CLI processes; this server
rides the AsyncClient, which never blocks.

The ask obligation is enforced where an MCP server can enforce it: the
hub keeps the ask ledger, and the inbox tool result restates the rule on
every turn that still has asks open.
"""

import json
import os
import uuid

from mcp.server.fastmcp import FastMCP

from . import protocol as P
from .async_client import AsyncClient
from .cli import HubError, Unreachable, WaitTimeout, decode_payload
from .daemon import _cwd_match

mcp = FastMCP("ocahub")


_IDENTITY = None


async def _identity():
    """(name, session) this MCP server answers for.

    The opencode stophook plugin registers the session under its real
    opencode session id, stamped with the session's cwd. The MCP server
    gets no session identity from opencode, so it finds that registration
    here: the most recent entry with our name in our directory. Two
    sessions born at once in one directory can cross-wire; set
    OCAHUB_SESSION to pin the identity in that case.
    """
    global _IDENTITY
    if _IDENTITY:
        return _IDENTITY
    name = os.environ.get("OCAHUB_NAME") or "opencode"
    pinned = os.environ.get("OCAHUB_SESSION")
    if pinned:
        _IDENTITY = (name, pinned)
        return _IDENTITY
    cwd = _cwd()
    c = AsyncClient()
    try:
        candidates = [
            s
            for s in ((await c.who()).sessions or [])
            if s.get("name") == name and s.get("cwd") and _cwd_match(s["cwd"], cwd)
        ]
    except (Unreachable, HubError):
        candidates = []
    finally:
        c.close()
    if candidates:
        _IDENTITY = (name, max(candidates, key=lambda s: s["last_seen"])["session"])
    else:
        # Nothing registered us (plugin absent or hub young): fall back to
        # a private session, so inbox still works name-level.
        _IDENTITY = (name, uuid.uuid4().hex)
    return _IDENTITY


def _json(meta, payload=None):
    out = meta.to_dict() if hasattr(meta, "to_dict") else dict(meta)
    if payload is not None:
        out["payload"] = decode_payload(payload)
    return json.dumps(out, separators=(",", ":"))


def _tool_error(e, hint="is the ocahub service running on this host?"):
    out = {"error": str(e)}
    if hint:
        out["hint"] = hint
    return json.dumps(out, separators=(",", ":"))


def _hub_reject(e):
    return _tool_error(e, hint=None)


def _cwd():
    return os.environ.get("OCAHUB_CWD") or os.getcwd()


async def _agents_list(cwd=None):
    c = AsyncClient()
    try:
        sessions = (await c.who()).sessions or []
        if cwd:
            # Substring either way: full paths, basenames and trailing
            # slashes all find their target.
            sessions = [s for s in sessions if s.get("cwd") and _cwd_match(s["cwd"], cwd)]
        return json.dumps(sessions, separators=(",", ":"))
    except Unreachable as e:
        return _tool_error(e)
    except HubError as e:
        return _hub_reject(e)
    finally:
        c.close()


async def _agent_send(to, message, kind, wait, timeout, topic, cwd=None):
    if kind == P.KIND_REPLY:
        return json.dumps(
            {"error": "kind=reply must go through agent_reply"}, separators=(",", ":")
        )
    if to and cwd:
        return json.dumps(
            {"error": "use either to or cwd, not both"}, separators=(",", ":")
        )
    if not to and not cwd:
        return json.dumps(
            {"error": "needs to (NAME or NAME@SESSION) or cwd"}, separators=(",", ":")
        )
    payload = (message or "").encode()
    c = AsyncClient()
    try:
        if kind == P.KIND_ASK and wait:
            ack, m, pl = await c.send_wait(
                to=to, topic=topic, kind=kind, payload=payload, wait=timeout, cwd=cwd
            )
            return json.dumps(
                {"ack": ack.to_dict(), "reply": {**m.to_dict(), "payload": decode_payload(pl)}},
                separators=(",", ":"),
            )
        ack = await c.send(to=to, topic=topic, kind=kind, payload=payload, cwd=cwd)
        if kind == P.KIND_ASK and ack.ok:
            ack.note = (
                f"ask sent; the target owes agent_reply(reply_to={ack.in_reply_to}) "
                "before ending its turn"
            )
        return _json(ack)
    except Unreachable as e:
        return _tool_error(e)
    except HubError as e:
        return _hub_reject(e)
    finally:
        c.close()


async def _agent_reply(reply_to, message, to=None):
    payload = (message or "").encode()
    c = AsyncClient()
    try:
        ack = await c.send(kind=P.KIND_REPLY, reply_to=reply_to, to=to, payload=payload)
        return _json(ack)
    except Unreachable as e:
        return _tool_error(e)
    except HubError as e:
        return _hub_reject(e)
    finally:
        c.close()


async def _agent_inbox(wait):
    name, session = await _identity()
    c = AsyncClient()
    try:
        if wait and wait > 0:
            ack, m, pl = await c.poll_wait(name, session, wait=wait, cwd=_cwd())
            messages = [{**m.to_dict(), "payload": decode_payload(pl)}]
        else:
            ack, delivers = await c.call(P.Poll(name=name, session=session, cwd=_cwd()))
            messages = [
                {**m.to_dict(), "payload": decode_payload(pl)} for m, pl in delivers
            ]
        asks_ack = (await c.call(P.Asks(name=name, session=session)))[0]
        asks = asks_ack.asks or []
        return json.dumps(
            {
                "you": {"name": name, "session": session},
                "mailbox_status": ack.status,
                "messages": messages,
                "unanswered_asks": asks,
                "note": (
                    "You have unanswered asks. Call agent_reply(reply_to=<ask id>) "
                    "for each one before ending your turn."
                    if asks
                    else None
                ),
            },
            separators=(",", ":"),
        )
    except Unreachable as e:
        return _tool_error(e)
    except HubError as e:
        return _hub_reject(e)
    except WaitTimeout as e:
        return _tool_error(e, hint=None)
    finally:
        c.close()


@mcp.tool()
async def agents_list(cwd: str | None = None) -> str:
    """List agent sessions registered on the message hub.

    Returns a JSON array: name, session, online, last_seen, caps, cwd,
    title (the human-facing session name), and asks (asks still owed by
    that session). Address a session as NAME or, to be specific,
    NAME@SESSION. With cwd, only sessions whose working directory matches
    (substring, either way) are listed.
    """
    return await _agents_list(cwd)


@mcp.tool()
async def agent_send(
    to: str | None = None,
    message: str = "",
    kind: str = "tell",
    wait: bool = False,
    timeout: float = 120.0,
    topic: str | None = None,
    cwd: str | None = None,
) -> str:
    """Send a message to an agent session on the hub.

    kind: "tell" is fire and forget. "ask" tells the target it owes a reply
    before ending its turn; with wait=true this call blocks until that
    reply arrives or timeout seconds pass (the honest way to ask a
    question). "reply" is not valid here; use agent_reply. Target the
    receiver with to (NAME or NAME@SESSION from agents_list) or with cwd
    (the most recent online session in a matching directory) - exactly one
    of the two.
    """
    return await _agent_send(to, message, kind, wait, timeout, topic, cwd)


@mcp.tool()
async def agent_reply(reply_to: str, message: str, to: str | None = None) -> str:
    """Answer an ask you received, by its id (the deliver's id or reply_to).

    Forgiving: when the ask is no longer tracked, the hub passes the
    message through as a plain tell, so a stale or mismatched reply is
    never lost. to is the fallback target if the asker cannot be found.
    """
    return await _agent_reply(reply_to, message, to)


@mcp.tool()
async def agent_inbox(wait: float = 0.0) -> str:
    """Drain messages addressed to you and list asks you owe.

    Call this at session start, after long sub-agent work, and before
    ending your turn. wait > 0 blocks up to that many seconds for the
    next message. An ask in unanswered_asks must be answered with
    agent_reply(reply_to=<ask id>) before you end your turn.
    """
    return await _agent_inbox(wait)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
