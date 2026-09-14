"""
The end-to-end checks: real opencode TUIs work the hub, nobody behind them.

The chain is the whole product path: sway paints foot, foot runs
pymux's client, the pymux server holds the pane opencode runs in,
opencode's model is the mock provider on this machine, and its MCP
server is the ocahub one built here against the daemon the `hub`
fixture started. A check drives the TUIs through pymux's control
socket and asserts on three channels: the hub's own client protocol,
the pane's text, and the picture the seat took. What fails tells you
which layer broke; what passes says all of them worked together.

The checks are async because the product is: the conversation check
runs two opencode instances at once, each a task in one task group,
the shape ocahub's users live in. The primitives are anyio's.
"""

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import anyio
import pytest

from ocahub import protocol as P

from mock_llm import MockLLM
from tui_harness import DEFAULT_TIMEOUT, Tui

CONFIG = {
    "$schema": "https://opencode.ai/config.json",
    "autoupdate": False,
    "permission": {
        "edit": "allow",
        "bash": "allow",
        "webfetch": "allow",
    },
}


def spawn_agent(work, hub, name, llm):
    """
    One agent's everything: fresh roots, the mock provider as the only
    model, the ocahub MCP server (from this build's PYTHONPATH), and a
    hub name to answer to. Returns the Tui, unstarted.
    """
    root = work / name
    config_dir = root / "config"
    for path in (
        config_dir / "opencode",
        root / "data",
        root / "cache",
        root / "state",
        root / "home",
        root / "project",
    ):
        path.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "init", "-q"],
        cwd=str(root / "project"),
        check=True,
        capture_output=True,
    )

    # The hub plugin, when the environment carries it: it owns the
    # session's hub registration, and the rename check stands on it.
    plugin = os.environ.get("OCAHUB_PLUGIN")
    if plugin and Path(plugin).exists():
        plugins = config_dir / "opencode" / "plugins"
        plugins.mkdir(parents=True, exist_ok=True)
        shutil.copy(plugin, plugins / "ocahub-stop-hook.ts")

    config = json.loads(json.dumps(CONFIG))
    # The model id is the agent's name, bare: the mock keys its scripts
    # by what the request's `model` field carries, which is the id and
    # not provider/id. `model` selects it as mock/<name>.
    config["model"] = "mock/%s" % name
    config["provider"] = {
        "mock": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Mock",
            "options": {"baseURL": llm.url, "apiKey": "mock-key"},
            "models": {
                name: {"name": name, "limit": {"context": 32000, "output": 4096}}
            },
        }
    }
    config["mcp"] = {
        "ocahub": {"type": "local", "command": ["ocahub-mcp"], "enabled": True}
    }
    (config_dir / "opencode" / "opencode.json").write_text(json.dumps(config, indent=2))

    env = {
        "XDG_CONFIG_HOME": str(config_dir),
        "XDG_DATA_HOME": str(root / "data"),
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_STATE_HOME": str(root / "state"),
        "HOME": str(root / "home"),
        "OCAHUB_RUNTIME_DIR": hub.runtime,
        "OCAHUB_STATE_DIR": hub.state,
        "OCAHUB_TIMEOUT": "60",
        "OCAHUB_NAME": name,
    }
    return Tui(root, root / "project", env)


async def hub_delivers(hub, recipient, needle, timeout=DEFAULT_TIMEOUT):
    """
    Poll the hub as the recipient would, until a delivery for the name
    carries the text. This is the client protocol end to end, not a
    peek at the database.

    One client for the whole wait, and every zmq call in a worker
    thread: `Client.close` ends in `ctx.destroy`, which blocks, and a
    blocking call on the event loop thread wedges the loop -- the
    heartbeats stop, the timeouts stop, and the test hangs forever.
    The sandbox reaches that state in a dozen polls; a fast machine
    may never see it, which is the worst kind of bug to leave behind.
    """
    client = hub.client()
    deadline = time.monotonic() + timeout
    last = None
    try:
        while time.monotonic() < deadline:
            ack, delivers = await anyio.to_thread.run_sync(
                lambda: client.call(P.Poll(name=recipient, session="e2e-check"))
            )
            for delivery in delivers:
                record = (
                    delivery.to_dict() if hasattr(delivery, "to_dict") else delivery
                )
                if needle in json.dumps(record, default=str):
                    return delivery
                last = record
            await anyio.sleep(1.0)
    finally:
        await anyio.to_thread.run_sync(client.close)
    raise AssertionError(
        "the hub never delivered %r to %s; the last poll was %r" % (needle, recipient, last)
    )


@pytest.mark.tui
@pytest.mark.anyio
async def test_opencode_tui_sends_to_the_hub(hub, tmp_path):
    """
    Open the session with a hello, then type the working prompt. The
    mock makes the model answer it with a call of the ocahub
    `agent_send` tool, so the only way the loop completes is opencode
    reaching the hub through its MCP server. The final answer is
    scripted text, so its appearance in the pane means the tool result
    came back and opencode spoke about it.
    """
    scenario = {
        "alpha": [
            {"text": "hello"},
            {
                "tool_call": {
                    "tool": "agent_send",
                    "arguments": {"to": "tester", "message": "hello from the TUI"},
                }
            },
            {"text": "LOOPDONE"},
        ]
    }
    with MockLLM(scenario) as llm:
        tui = spawn_agent(tmp_path, hub, "alpha", llm)
        try:
            await tui.start()
            await tui.hello()
            await tui.send_keys("tell tester hello from the TUI", enter=True)
            await hub_delivers(hub, "tester", "hello from the TUI")
            await tui.wait(lambda t: "LOOPDONE" in t, timeout=DEFAULT_TIMEOUT)
            picture = await tui.screenshot(tmp_path / "tui.png")
            assert picture.exists()
        finally:
            await tui.stop()
            names = [
                t.get("function", {}).get("name")
                for r in llm.requests
                for t in r.get("tools") or []
            ]
            print("mock saw tools: %s" % sorted(set(names)))
            print("mock exhausted: %s" % llm.exhausted)


@pytest.mark.tui
@pytest.mark.anyio
async def test_two_agents_converse_through_the_hub(hub, tmp_path):
    """
    Two opencode TUIs, one conversation, the hub in the middle: alpha
    asks and waits on its blocked tool call, beta learns of the ask
    through its inbox, replies by the ask's id, and alpha's pane shows
    the answer that travelled beta -> hub -> alpha. The reply's id is
    not known to any script in advance -- beta's script writes a
    placeholder and the mock fills it from the conversation, the same
    substitution a real model does when it reads its tool results.

    Every parallel piece runs inside one task group, so a failure
    cancels its siblings and the group waits for them to stop.
    """
    scenario = {
        "alpha": [
            {"text": "hello"},
            {
                "tool_call": {
                    "tool": "agent_send",
                    "arguments": {
                        "to": "beta",
                        "kind": "ask",
                        "wait": True,
                        "timeout": 120,
                        "message": "what is the plan?",
                    },
                }
            },
            {"text": "GOTREPLY"},
        ],
        "beta": [
            {"text": "hello"},
            {"tool_call": {"tool": "agent_inbox", "arguments": {"wait": 120}}},
            {
                "tool_call": {
                    "tool": "agent_reply",
                    "arguments": {"reply_to": "$ask_id", "message": "the plan is ocahub"},
                }
            },
            {"text": "REPLIED"},
        ],
    }
    with MockLLM(scenario) as llm:
        alpha = spawn_agent(tmp_path, hub, "alpha", llm)
        beta = spawn_agent(tmp_path, hub, "beta", llm)
        try:
            # Both agents come up at once; each seat is its own.
            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.start)
                tg.start_soon(beta.start)

            # The hellos open the sessions; without a first prompt
            # there is no session, and nothing to rename or address.
            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.hello)
                tg.start_soon(beta.hello)

            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.send_keys, "ask beta what the plan is", True)
                tg.start_soon(beta.send_keys, "watch your inbox and answer", True)

            async with anyio.create_task_group() as tg:
                tg.start_soon(
                    alpha.wait, lambda t: "GOTREPLY" in t
                )
                tg.start_soon(beta.wait, lambda t: "REPLIED" in t)

            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.screenshot, tmp_path / "alpha.png")
                tg.start_soon(beta.screenshot, tmp_path / "beta.png")

            # The ask is answered on the hub's ledger, not merely shown:
            # the ledger is the thing agents read, so that is what a
            # clean conversation leaves behind.
            client = hub.client()
            try:
                ack = (
                    await anyio.to_thread.run_sync(
                        lambda: client.call(P.Asks(name="alpha", session="test"))
                    )
                )[0]
                assert not (ack.asks or []), "alpha's ask never got its reply"
            finally:
                await anyio.to_thread.run_sync(client.close)
        finally:
            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.stop)
                tg.start_soon(beta.stop)


@pytest.mark.tui
@pytest.mark.anyio
async def test_rename_reaches_the_hub_at_once(hub, tmp_path):
    """
    Rename the session from the TUI and watch the hub: the new title
    must be there within seconds. The plugin's keepalive sweep would
    get there in forty-five; only the session.updated path satisfies
    this window, which is the point -- renaming before agents address
    each other is the normal flow, and a stale title is a message to a
    name nobody asked for.
    """
    tui = None
    try:
        with MockLLM({"alpha": [{"text": "hello"}]}) as llm:
            tui = spawn_agent(tmp_path, hub, "alpha", llm)
            await tui.start()
            await tui.hello()
            await tui.rename("Plan Discussion")

            client = hub.client()
            deadline = time.monotonic() + 10
            seen = ""
            try:
                while time.monotonic() < deadline:
                    ack = (
                        await anyio.to_thread.run_sync(lambda: client.call(P.Who()))
                    )[0]
                    titles = [
                        s.get("title")
                        for s in (ack.sessions or [])
                        if s.get("name") == "alpha"
                    ]
                    if any(t == "Plan Discussion" for t in titles):
                        return
                    seen = repr(titles)
                    await anyio.sleep(0.5)
            finally:
                await anyio.to_thread.run_sync(client.close)
            pane = await tui.capture()
            raise AssertionError(
                "the hub still had %s after 10s -- the rename did not travel by "
                "event; the pane showed:\n%s" % (seen, pane)
            )
    finally:
        if tui is not None:
            await tui.stop()
