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
runs two opencode instances at once, the way the hub's users do.
"""

import asyncio
import json
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
    peek at the database; the sync client runs in a thread so the
    loop keeps working while it waits.
    """
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        client = hub.client()
        try:
            ack, delivers = await anyio.to_thread.run_sync(
                lambda: client.call(P.Poll(name=recipient, session="e2e-check"))
            )
        finally:
            client.close()
        for delivery in delivers:
            record = delivery.to_dict() if hasattr(delivery, "to_dict") else delivery
            if needle in json.dumps(record, default=str):
                return delivery
            last = record
        await asyncio.sleep(1.0)
    raise AssertionError(
        "the hub never delivered %r to %s; the last poll was %r" % (needle, recipient, last)
    )


@pytest.mark.anyio
async def test_opencode_tui_sends_to_the_hub(hub, tmp_path):
    """
    Type one prompt at the TUI. The mock makes the model answer with a
    call of the ocahub `agent_send` tool, so the only way the loop
    completes is opencode reaching the hub through its MCP server. The
    final answer is scripted text, so its appearance in the pane means
    the tool result came back and opencode spoke about it.
    """
    scenario = {
        "alpha": [
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
    """
    scenario = {
        "alpha": [
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
            await asyncio.gather(alpha.start(), beta.start())
            await asyncio.gather(
                alpha.send_keys("ask beta what the plan is", enter=True),
                beta.send_keys("watch your inbox and answer", enter=True),
            )
            await asyncio.gather(
                alpha.wait(lambda t: "GOTREPLY" in t, timeout=DEFAULT_TIMEOUT),
                beta.wait(lambda t: "REPLIED" in t, timeout=DEFAULT_TIMEOUT),
            )
            await asyncio.gather(
                alpha.screenshot(tmp_path / "alpha.png"),
                beta.screenshot(tmp_path / "beta.png"),
            )

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
                client.close()
        finally:
            await asyncio.gather(alpha.stop(), beta.stop())
