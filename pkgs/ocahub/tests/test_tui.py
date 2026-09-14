"""
The end-to-end checks: real agent TUIs work the hub, nobody behind
them.

The chain is the whole product path: sway paints foot, foot runs
pymux's client, the pymux server holds the pane the agent runs in,
the agent's model is fakellm on this machine, and its MCP server is
the ocahub one built here against the daemon the `hub` fixture
started. A check drives the TUIs through pymux's control socket and
asserts on three channels: the hub's own client protocol, the pane's
text, and the picture the seat took. What fails tells you which layer
broke; what passes says all of them worked together.

The mock's behavior is the rules each check loads -- see
fakellm_harness for the matcher facts that shape them. Three of them
show up everywhere: rules sit in reverse sequence, so the flow's last
turn is the first rule and every rule is keyed on text only its own
turn has; tool-call arguments are never seen, so a rule keys on what
the agent has already been shown; and opencode offers its MCP tools
under the server prefix -- `ocahub_agent_send`, not `agent_send` --
which fakellm matches exactly.

The checks are async because the product is: the conversation check
runs two agents at once, each a task in one task group, the shape
ocahub's users live in. The primitives are anyio's.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import anyio
import pytest

from ocahub import protocol as P

from fakellm_harness import Fakellm
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
    One agent's everything: fresh roots, fakellm as the only model,
    the ocahub MCP server (from this build's PYTHONPATH), and a hub
    name to answer to. Returns the Tui, unstarted.
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
    # The model id is the agent's name, bare: the rules key on the
    # request's `model` field, which is the id and not provider/id.
    # `model` selects it as mock/<name>.
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


def spawn_claude(work, hub, name, llm):
    """
    One claude-code session's everything, beside spawn_agent: fakellm
    as the only provider, the ocahub MCP server under this build's
    PATH, permissions bypassed so nothing stops for a prompt, and
    onboarding pre-seeded so the first screen is the prompt. The
    monitor the wake stands on is not set up here -- the session's
    own script starts it, as the real flow would.
    """
    root = work / name
    for path in (root / "home" / ".claude", root / "project"):
        path.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "init", "-q"],
        cwd=str(root / "project"),
        check=True,
        capture_output=True,
    )
    # The model id must be one claude's own catalog knows -- an
    # unknown one is refused client-side, before any API traffic. The
    # rules key on the same string.
    model = "claude-sonnet-4-5"
    settings = {
        "env": {
            # The Anthropic client appends /v1/messages to the base
            # url, so the bare origin goes here.
            "ANTHROPIC_BASE_URL": llm.origin,
            "ANTHROPIC_AUTH_TOKEN": "mock-key",
            "ANTHROPIC_MODEL": model,
            "ANTHROPIC_SMALL_FAST_MODEL": model,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_AUTOUPDATER": "1",
        },
        "model": model,
        "permissions": {"defaultMode": "bypassPermissions"},
        "mcpServers": {
            "ocahub": {
                "command": "ocahub-mcp",
                "args": [],
                "env": {
                    "OCAHUB_RUNTIME_DIR": hub.runtime,
                    "OCAHUB_STATE_DIR": hub.state,
                    "OCAHUB_NAME": name,
                    "OCAHUB_TIMEOUT": "60",
                },
            }
        },
    }
    (root / "home" / ".claude" / "settings.json").write_text(json.dumps(settings, indent=2))
    # The project-scoped MCP config, as well as the settings one: which
    # of the two this version reads is its own business, and a session
    # with neither has no ocahub tools to call.
    (root / "project" / ".mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "ocahub": {
                        "command": "ocahub-mcp",
                        "args": [],
                        "env": {
                            "OCAHUB_RUNTIME_DIR": hub.runtime,
                            "OCAHUB_STATE_DIR": hub.state,
                            "OCAHUB_NAME": name,
                            "OCAHUB_TIMEOUT": "60",
                        },
                    }
                }
            },
            indent=2,
        )
    )
    # The screens claude puts before the prompt, pre-answered: the
    # folder trust dialog reads its answer from the project entry, and
    # a "no" there is a clean exit -- which looks exactly like a crash
    # with the pane already gone.
    (root / "home" / ".claude.json").write_text(
        json.dumps(
            {
                "hasCompletedOnboarding": True,
                "theme": "dark",
                "bypassPermissionsModeAccepted": True,
                "projects": {
                    str(root / "project"): {"hasTrustDialogAccepted": True}
                },
            }
        )
    )
    # claude's dying words die with the pane: pymux exits when its last
    # session's process does, and a TUI that crashes at startup leaves
    # nothing else. The pane runs a wrapper that keeps --debug's
    # stderr in a file the run's evidence copies out. Stdout stays the
    # pty -- a piped stdout is how claude decides it is in --print
    # mode, and print mode wants a prompt on argv.
    wrapper = root / "claude-wrapper.sh"
    wrapper.write_text(
        "#!/bin/sh\n"
        'cd "%s"\n'
        "claude --debug 2>claude-session.log\n"
        % (root / "project")
    )
    wrapper.chmod(0o755)
    env = {
        "HOME": str(root / "home"),
        "OCAHUB_RUNTIME_DIR": hub.runtime,
        "OCAHUB_STATE_DIR": hub.state,
        "OCAHUB_TIMEOUT": "60",
        "OCAHUB_NAME": name,
    }
    return Tui(root, root / "project", env, command=str(wrapper))


async def hub_delivers(hub, recipient, needle, timeout=DEFAULT_TIMEOUT):
    """
    Poll the hub as the recipient would, until a delivery for the name
    carries the text. This is the client protocol end to end, not a
    peek at the database.

    One client for the whole wait, every zmq call in a worker thread,
    and the whole loop inside one timeout scope: `Client.close` ends
    in `ctx.destroy`, which blocks, and a blocking call on the event
    loop thread wedges the loop -- the heartbeats stop, the timeouts
    stop, and the test hangs forever. The sandbox reaches that state
    in a dozen polls; a fast machine may never see it, which is the
    worst kind of bug to leave behind.
    """
    client = hub.client()
    last = None
    try:
        with anyio.fail_after(timeout):
            while True:
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
    except TimeoutError:
        raise AssertionError(
            "the hub never delivered %r to %s; the last poll was %r"
            % (needle, recipient, last)
        )
    finally:
        await anyio.to_thread.run_sync(client.close)


async def wait_for_ask(hub, target, timeout=15.0):
    """
    Read the ask id off the ledger. An ask is on the ledger the moment
    it is sent -- delivery to the target waits for the target's own
    poll -- and that gap is where the checks stage the reply rule: the
    id is a hub fact, learned the way any client would learn it.

    The ledger is name-level, so the session here is just a handle;
    it invents nothing the hub would route mail to.
    """
    client = hub.client()
    last = None
    try:
        with anyio.fail_after(timeout):
            while True:
                ack = (
                    await anyio.to_thread.run_sync(
                        lambda: client.call(
                            P.Asks(name=target, session="ledger-reader")
                        )
                    )
                )[0]
                asks = ack.asks or []
                if asks:
                    ask = asks[0]
                    return ask["id"] if isinstance(ask, dict) else ask.id
                last = asks
                await anyio.sleep(0.2)
    except TimeoutError:
        raise AssertionError("no ask on the ledger for %s: %r" % (target, last))
    finally:
        await anyio.to_thread.run_sync(client.close)


@pytest.mark.tui
@pytest.mark.anyio
async def test_opencode_tui_sends_to_the_hub(hub, tmp_path):
    """
    Open the session with a hello, then type the working prompt. The
    rules make the model answer it with a call of the ocahub
    `agent_send` tool, so the only way the loop completes is opencode
    reaching the hub through its MCP server. The final answer is rule
    text, so its appearance in the pane means the tool result came
    back and opencode spoke about it.
    """
    # The rules go in before the server starts: start() writes the
    # config, and a rule added after enter() is a rule the server
    # never reads.
    llm = Fakellm(tmp_path, tmp_path / "fakellm.log")
    # Reverse sequence: the loop's last turn is keyed on the send
    # ack, which exists in no turn before it; the kickoff on the
    # prompt itself. 'ok":true' is in every hub ack, and in
    # nothing else the conversation has seen.
    llm.rule(
        "loop-done",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "tool_result_contains": 'ok":true',
        },
        content="LOOPDONE",
    )
    llm.rule(
        "kickoff",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "messages_contain": "tell tester",
        },
        tool_calls=[
            {
                "name": "ocahub_agent_send",
                "arguments": {"to": "tester", "message": "hello from the TUI"},
            }
        ],
    )
    # The greeting: last, because "hello" is in every later turn's
    # history, and first-match would otherwise eat the working turn's
    # request.
    llm.rule(
        "hello",
        {"model_matches": "alpha", "messages_contain": "hello"},
        content="hello",
    )
    with llm:
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
            print("fakellm stats: %s" % json.dumps(llm.stats()))


@pytest.mark.tui
@pytest.mark.anyio
async def test_two_agents_converse_through_the_hub(hub, tmp_path):
    """
    Two opencode TUIs, one conversation, the hub in the middle: alpha
    asks and waits on its blocked tool call, beta learns of the ask
    through its inbox, replies by the ask's id, and alpha's pane shows
    the answer that travelled beta -> hub -> alpha.

    The reply's id is not known to any rule in advance. Alpha's ask
    sits on the ledger the moment it is sent, and delivery waits for
    beta's own inbox poll; in that gap the check reads the id and
    stages the reply rule, the same substitution a real model does
    reading its tool results, minus the regex.

    Every parallel piece runs inside one task group, so a failure
    cancels its siblings and the group waits for them to stop.
    """
    # The rules go in before the server starts -- see the single-agent
    # check.
    llm = Fakellm(tmp_path, tmp_path / "fakellm.log")
    # alpha: the reply's payload text exists in alpha's conversation
    # only once beta has composed it.
    llm.rule(
        "alpha-got-reply",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "tool_result_contains": "the plan is ocahub",
        },
        content="GOTREPLY",
    )
    llm.rule(
        "alpha-ask",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "messages_contain": "ask beta",
        },
        tool_calls=[
            {
                "name": "ocahub_agent_send",
                "arguments": {
                    "to": "beta",
                    "kind": "ask",
                    "wait": True,
                    "timeout": 120,
                    "message": "what is the plan?",
                },
            }
        ],
    )
    llm.rule(
        "alpha-hello",
        {"model_matches": "alpha", "messages_contain": "hello"},
        content="hello",
    )
    # beta, before the ask id is known: only the inbox. The greeting
    # comes last, as in the single-agent check: "hello" is in every
    # later turn's history.
    llm.rule(
        "beta-inbox",
        {
            "model_matches": "beta",
            "tools_include": "ocahub_agent_inbox",
            "messages_contain": "watch your inbox",
        },
        tool_calls=[{"name": "ocahub_agent_inbox", "arguments": {"wait": 120}}],
    )
    llm.rule(
        "beta-hello",
        {"model_matches": "beta", "messages_contain": "hello"},
        content="hello",
    )
    with llm:
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

            # Alpha asks first: beta's inbox is not attached yet, so
            # the ask waits on the ledger rather than flying to
            # nobody.
            await alpha.send_keys("ask beta what the plan is", enter=True)

            # The gap: stage the reply rule with the real id, ahead
            # of the inbox rule so it wins matching once the ask
            # result is in.
            ask_id = await wait_for_ask(hub, "beta")
            llm.rule(
                "beta-replied",
                {
                    "model_matches": "beta",
                    "tool_result_contains": 'ok":true',
                },
                content="REPLIED",
                before="beta-inbox",
            )
            llm.rule(
                "beta-reply",
                {
                    "model_matches": "beta",
                    "tools_include": "ocahub_agent_inbox",
                    "tool_result_contains": '"kind":"ask"',
                },
                tool_calls=[
                    {
                        "name": "ocahub_agent_reply",
                        "arguments": {
                            "reply_to": ask_id,
                            "message": "the plan is ocahub",
                        },
                    }
                ],
                before="beta-inbox",
            )
            llm.reload()

            await beta.send_keys("watch your inbox and answer", enter=True)

            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.wait, lambda t: "GOTREPLY" in t)
                tg.start_soon(beta.wait, lambda t: "REPLIED" in t)

            async with anyio.create_task_group() as tg:
                tg.start_soon(alpha.screenshot, tmp_path / "alpha.png")
                tg.start_soon(beta.screenshot, tmp_path / "beta.png")

            # The ask is answered on the hub's ledger, not merely
            # shown: the ledger is the thing agents read, so that is
            # what a clean conversation leaves behind.
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
            print("fakellm stats: %s" % json.dumps(llm.stats()))


@pytest.mark.tui
@pytest.mark.anyio
async def test_claude_answers_a_hub_ask(hub, tmp_path):
    """
    The second agent format, end to end: claude-code against fakellm,
    woken by the monitor it started in the background. Alpha -- an
    opencode, as before -- asks and blocks; the ask reaches claude
    through `ocac monitor`, whose completed background task is the
    wake; claude answers by the ask's id through the MCP server, and
    alpha's pane shows the answer that travelled claude -> hub ->
    alpha.

    The reply rule is staged off the ledger, as in the two-agent
    check. The monitor's `sleep 5` is the seam that makes the gap
    real: it keeps the wake unattached until the rules hold the id,
    so the wake and the reply cannot race the staging.

    The clean ledger is read off the MCP server's own registration,
    the one whose session id the hub knows.
    """
    # The rules go in before the server starts -- see the single-agent
    # check.
    llm = Fakellm(tmp_path, tmp_path / "fakellm.log")
    # alpha: unchanged from the two-agent check, target claude.
    llm.rule(
        "alpha-got-reply",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "tool_result_contains": "the plan is ocahub",
        },
        content="GOTREPLY",
    )
    llm.rule(
        "alpha-ask",
        {
            "model_matches": "alpha",
            "tools_include": "ocahub_agent_send",
            "messages_contain": "ask claude",
        },
        tool_calls=[
            {
                "name": "ocahub_agent_send",
                "arguments": {
                    "to": "claude",
                    "kind": "ask",
                    "wait": True,
                    "timeout": 120,
                    "message": "what is the plan?",
                },
            }
        ],
    )
    llm.rule(
        "alpha-hello",
        {"model_matches": "alpha", "messages_contain": "hello"},
        content="hello",
    )
    # claude, before the ask id is known: the wake is armed, and the
    # turn that reports it armed. Reverse sequence, keyed on text
    # only the turn has seen: the notification turn before the
    # monitor-report turn, the monitor-report turn before the
    # kickoff.
    llm.rule(
        "claude-monitoring",
        {
            "model_matches": "claude-sonnet*",
            "messages_contain": "command running in background",
        },
        content="MONITORING",
    )
    llm.rule(
        "claude-kickoff",
        {
            "model_matches": "claude-sonnet*",
            "tools_include": "Bash",
            "messages_contain": "hello",
        },
        tool_calls=[
            {
                "name": "Bash",
                "arguments": {
                    # Everything literal, nothing from the
                    # environment: measured, claude's bash task does
                    # not pass OCAHUB_* through, and a monitor left to
                    # the default runtime dir answers from the wrong
                    # hub. The sleep holds the wake back while the
                    # check stages the id; the wake line goes to a
                    # file beside the pane, which the run's evidence
                    # copies out.
                    "command": (
                        "sleep 5; ocac --runtime-dir %s monitor"
                        " --name claude --session claude-s1 --wait 180"
                        " > claude-wake.json 2>> claude-monitor.log"
                        % hub.runtime
                    ),
                    "run_in_background": True,
                },
            }
        ],
    )
    with llm:
        # TEMP: the wire's ground truth -- claude goes through a
        # logging proxy so a non-matching rule can be judged on the
        # bytes.
        from fakellm_harness import LoggingProxy

        proxy = LoggingProxy(llm.port, tmp_path / "llm-wire.log")
        await proxy.start()
        claude = spawn_claude(tmp_path, hub, "claude", proxy)
        alpha = spawn_agent(tmp_path, hub, "alpha", llm)
        try:
            async with anyio.create_task_group() as tg:
                tg.start_soon(claude.start)
                tg.start_soon(alpha.start)

            # The wake is armed first: the monitor is in the
            # background before anything is sent to anybody.
            await claude.hello(reply="monitoring")
            await alpha.hello()
            await alpha.send_keys("ask claude what the plan is", enter=True)

            # The gap, held open by the monitor's sleep: stage the
            # reply rule with the real id.
            ask_id = await wait_for_ask(hub, "claude")
            llm.rule(
                "claude-replied",
                {
                    "model_matches": "claude-sonnet*",
                    "tool_result_contains": 'ok":true',
                },
                content="REPLIED",
                before="claude-monitoring",
            )
            llm.rule(
                "claude-answer",
                {
                    "model_matches": "claude-sonnet*",
                    "tools_include": "mcp__ocahub__agent_reply",
                    "messages_contain": "task-notification",
                },
                tool_calls=[
                    {
                        "name": "mcp__ocahub__agent_reply",
                        "arguments": {
                            "reply_to": ask_id,
                            "message": "the plan is ocahub",
                        },
                    }
                ],
                before="claude-monitoring",
            )
            llm.reload()

            # TEMP: what the mock recorded seeing -- the seen tool
            # results are the truth about the wire.
            print("fakellm conversations: %s" % json.dumps(llm.conversations()))

            async with anyio.create_task_group() as tg:
                tg.start_soon(claude.wait, lambda t: "REPLIED" in t)
                tg.start_soon(alpha.wait, lambda t: "GOTREPLY" in t)

            client = hub.client()
            try:
                who = (
                    await anyio.to_thread.run_sync(lambda: client.call(P.Who()))
                )[0]
                claude_sessions = [
                    s for s in (who.sessions or []) if s.get("name") == "claude"
                ]
                assert claude_sessions, "claude's MCP server never registered"
                assert all(
                    not (s.get("asks") or []) for s in claude_sessions
                ), "claude's ask never got its reply"
            finally:
                await anyio.to_thread.run_sync(client.close)
        finally:
            async with anyio.create_task_group() as tg:
                tg.start_soon(claude.stop)
                tg.start_soon(alpha.stop)
            proxy.stop()
            print("fakellm stats: %s" % json.dumps(llm.stats()))


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
    # The rules go in before the server starts -- see the single-agent
    # check.
    llm = Fakellm(tmp_path, tmp_path / "fakellm.log")
    llm.rule(
        "hello",
        {"model_matches": "alpha", "messages_contain": "hello"},
        content="hello",
    )
    try:
        with llm:
            tui = spawn_agent(tmp_path, hub, "alpha", llm)
            await tui.start()
            await tui.hello()
            await tui.rename("Plan Discussion")

            client = hub.client()
            seen = ""
            try:
                with anyio.fail_after(10):
                    while True:
                        ack = (
                            await anyio.to_thread.run_sync(
                                lambda: client.call(P.Who())
                            )
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
            except TimeoutError:
                pass
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
