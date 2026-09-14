"""
A scripted AI provider: the model the TUI tests run against.

The point of the TUI checks is a real agent loop with nobody behind
the model. This server stands in for the provider, on two wire
formats: opencode speaks OpenAI chat (`POST /v1/chat/completions`),
claude-code speaks Anthropic messages (`POST /v1/messages`). Both
answer with a queued script of turns, streaming or not, and record
every request they saw. A check then asserts on the record, the way
a hub check asserts on its daemon's state.

The server is one asyncio loop in a thread of its own, and its scripts
are keyed by model: `MockLLM({"alpha": [...], "beta": [...]})` serves
several agents from one port, each none the wiser. That is what the
parallel checks stand on -- several agents, one provider, no blocking
anywhere on the test's own loop.

A turn is one of:

    {"text": "done"}                     # a plain answer, and the loop ends
    {"tool_call": {"tool": "agent_send", # resolve the prefixed name from
                                         # the tools the client offered
                   "arguments": {"to": "beta", "message": "ping"}}}

The tool arrives in the request's `tools` under the name the client
gives it -- the MCP server id is the prefix -- while the script spells
the tool the way the MCP server does, so the resolution happens here.

Requests that carry no `tools` are the small side calls the agents
make beside the loop -- the session title is one. They take
`small_answer` and never consume a scripted turn: the script belongs
to the agent loop, which is the only thing a check scripts.
"""

import asyncio
import json
import threading

#: The per-model script, served front to back.
Turns = dict


class _HTTP:
    """
    The minimal HTTP the mock needs: parse the request head, read the
    body, answer once. No keep-alive; the AI SDK opens what it needs.
    """

    def __init__(self, reader, writer, server):
        self.reader = reader
        self.writer = writer
        self.server = server

    async def serve(self):
        try:
            head = await self.reader.readuntil(b"\r\n\r\n")
        except (asyncio.IncompleteReadError, ConnectionError):
            return
        try:
            length = 0
            for line in head.decode(errors="replace").splitlines():
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1])
            body = await self.reader.readexactly(length) if length else b""
            line = head.decode(errors="replace").splitlines()[0]
            method, path, _ = line.split(" ", 2)
        except (ValueError, IndexError):
            await self.answer(b"400 Bad Request", b"text/plain", b"bad request")
            return

        if method == "GET" and path.rstrip("/").endswith("/models"):
            payload = json.dumps(
                {"object": "list", "data": [{"id": m, "object": "model"} for m in self.server.models]}
            ).encode()
            await self.answer(b"200 OK", b"application/json", payload)
            return

        route = path.rstrip("/")
        if method != "POST" or not (
            route.endswith("/chat/completions") or route.endswith("/messages")
        ):
            await self.answer(b"404 Not Found", b"text/plain", b"not found")
            return

        try:
            request = json.loads(body)
        except ValueError:
            request = {"_unparsed": body.decode(errors="replace")}
        self.server.requests.append(request)

        # The request's model is the bare id as configured; tolerate a
        # provider-prefixed spelling too.
        model = request.get("model", "mock")
        script = self.server.turns.get(model) or self.server.turns.get(
            model.split("/")[-1]
        ) or []
        if not request.get("tools"):
            # A small side call: not the agent loop, not the script's.
            turn = {"text": self.server.small_answer}
        elif script:
            turn = script.pop(0)
        else:
            turn = {"text": "(mock script exhausted)"}
        self.server.exhausted = all(not t for t in self.server.turns.values())

        if route.endswith("/messages"):
            await self.serve_anthropic(request, turn)
            return
        message, finish = _answer(turn, request)
        if request.get("stream"):
            await self.stream(message, finish, request)
        else:
            payload = _body(request, message, finish, stream=False)
            await self.answer(b"200 OK", b"application/json", json.dumps(payload).encode())

    async def serve_anthropic(self, request, turn):
        """
        The Anthropic messages route: one scripted turn becomes one
        content block -- text, or tool_use -- inside a message. The
        stream is the event sequence the client SDK reassembles, not
        chat chunks; the connection closes after, as above.
        """
        block, stop = _answer_anthropic(turn, request)
        if not request.get("stream"):
            payload = {
                "id": "msg_mock",
                "type": "message",
                "role": "assistant",
                "model": request.get("model", "mock"),
                "content": [block],
                "stop_reason": stop,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
            await self.answer(b"200 OK", b"application/json", json.dumps(payload).encode())
            return

        head = (
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
        )
        self.writer.write(head)
        await self.writer.drain()

        async def event(name, payload):
            chunk = (
                b"event: " + name.encode() + b"\ndata: " + json.dumps(payload).encode() + b"\n\n"
            )
            self.writer.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            await self.writer.drain()

        await event(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_mock",
                    "type": "message",
                    "role": "assistant",
                    "model": request.get("model", "mock"),
                    "content": [],
                    "stop_reason": None,
                    "usage": {"input_tokens": 1, "output_tokens": 0},
                },
            },
        )
        if block["type"] == "tool_use":
            await event(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {
                        "type": "tool_use",
                        "id": block["id"],
                        "name": block["name"],
                        "input": {},
                    },
                },
            )
            await event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {
                        "type": "input_json_delta",
                        "partial_json": json.dumps(block["input"]),
                    },
                },
            )
        else:
            await event(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            )
            await event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": block["text"]},
                },
            )
        await event("content_block_stop", {"type": "content_block_stop", "index": 0})
        await event(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop, "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        )
        await event("message_stop", {"type": "message_stop"})
        self.writer.write(b"0\r\n\r\n")
        await self.writer.drain()

    async def answer(self, status, kind, body):
        self.writer.write(
            b"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s"
            % (status, kind, len(body), body)
        )
        await self.writer.drain()

    async def stream(self, message, finish, request):
        """
        The chat stream: one event per chunk, the [DONE] mark at the
        end, and the connection closed after -- the mock is not a
        keep-alive citizen, and nothing minds.
        """
        head = (
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
        )
        self.writer.write(head)
        await self.writer.drain()

        async def event(delta=None, the_finish=None):
            payload = _body(request, delta, the_finish, stream=True)
            chunk = b"data: " + json.dumps(payload).encode() + b"\n\n"
            self.writer.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            await self.writer.drain()

        await event({"role": "assistant", "content": ""})
        if "tool_calls" in message:
            await event({"tool_calls": message["tool_calls"]})
        else:
            await event({"content": message.get("content", "")})
        await event(the_finish=finish)
        done = b"data: [DONE]\n\n"
        self.writer.write(b"%x\r\n%s\r\n" % (len(done), done))
        self.writer.write(b"0\r\n\r\n")
        await self.writer.drain()


def _answer(turn, request):
    """
    The assistant message and finish reason one scripted turn becomes,
    in OpenAI chat shape.
    """
    if "tool_call" in turn:
        wanted = turn["tool_call"]["tool"]
        name = _offered_name(request, wanted)
        ask_id = _ask_id_from(request)
        arguments = {
            key: _substitute(value, ask_id)
            for key, value in turn["tool_call"].get("arguments", {}).items()
        }
        return (
            {
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": name, "arguments": json.dumps(arguments)},
                    }
                ]
            },
            "tool_calls",
        )
    return {"content": turn.get("text", "")}, "stop"


def _answer_anthropic(turn, request):
    """
    The content block and stop reason one scripted turn becomes, in
    Anthropic messages shape. The script's tool spelling is resolved
    against the flat `tools` the same way the chat route resolves it
    against the nested one.
    """
    if "tool_call" in turn:
        wanted = turn["tool_call"]["tool"]
        name = _offered_name(request, wanted)
        ask_id = _ask_id_from(request)
        arguments = {
            key: _substitute(value, ask_id)
            for key, value in turn["tool_call"].get("arguments", {}).items()
        }
        return (
            {"type": "tool_use", "id": "toolu_mock", "name": name, "input": arguments},
            "tool_use",
        )
    return {"type": "text", "text": turn.get("text", "")}, "end_turn"


def _ask_id_from(request):
    """
    The id of the ask the agent was most recently shown.

    A scripted reply answers the ask the agent was just shown, and the
    only place the id exists is the conversation: the script writes
    `$ask_id` where it goes, and this is what the placeholder means.
    Both wire shapes are scanned, most recent first -- OpenAI tool
    messages, and Anthropic user turns whose blocks carry a tool
    result or the plain text a background task's completion arrives
    as. Any JSON object with an `id` at the top or under `messages`
    counts; the hub's delivery line and the inbox result are the two
    shapes that exist.
    """
    for message in reversed(request.get("messages") or []):
        for text in _message_strings(message):
            try:
                parsed = json.loads(text)
            except ValueError:
                continue
            if not isinstance(parsed, dict):
                continue
            if isinstance(parsed.get("id"), str):
                return parsed["id"]
            for entry in parsed.get("messages") or []:
                if isinstance(entry, dict) and isinstance(entry.get("id"), str):
                    return entry["id"]
    return None


def _message_strings(message):
    """
    The JSON-candidate strings one message carries, in either wire
    shape: an OpenAI tool message's content, an Anthropic block list's
    tool_result contents and texts, a plain string content.
    """
    content = message.get("content")
    if content is None:
        return []
    if isinstance(content, str):
        return [content]
    out = []
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_result":
            inner = block.get("content")
            if isinstance(inner, str):
                out.append(inner)
            elif isinstance(inner, list):
                out.extend(
                    b.get("text", "")
                    for b in inner
                    if isinstance(b, dict) and b.get("type") == "text"
                )
        elif block.get("type") == "text":
            out.append(block.get("text", ""))
    return [s for s in out if s]


def _substitute(value, ask_id):
    if isinstance(value, str) and "$ask_id" in value:
        return value.replace("$ask_id", ask_id or "UNKNOWN-ASK")
    return value


def _offered_name(request, wanted):
    """
    The name the client gave the tool the script calls, or the script's
    own spelling when the client offered nothing by that shape. Both
    wire shapes: OpenAI nests the name under `function`, Anthropic
    spells it flat.
    """
    for tool in request.get("tools") or []:
        name = tool.get("function", {}).get("name") or tool.get("name", "")
        if name == wanted or name.endswith("_" + wanted) or name.endswith("." + wanted):
            return name
    return wanted


def _body(request, delta_or_message, finish, stream):
    choice = {"index": 0, "finish_reason": finish}
    choice["delta" if stream else "message"] = delta_or_message
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion.chunk" if stream else "chat.completion",
        "created": 0,
        "model": request.get("model", "mock"),
        "choices": [choice],
    }


class MockLLM:
    """
    The server, its address, and the record of what it was asked.

    `turns` maps a model name to that model's script. `requests` is
    every parsed request body in arrival order; the tools list of the
    first one is how a check says the MCP tools were offered.
    """

    def __init__(self, turns, small_answer="New session"):
        self.turns = {model: list(script) for model, script in turns.items()}
        self.small_answer = small_answer
        self.models = list(self.turns) or ["test"]
        self.requests = []
        self.exhausted = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._started = threading.Event()
        self._loop = None
        self._server = None

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1" % self.port

    @property
    def port(self):
        return self._port

    @property
    def server_address(self):
        return ("127.0.0.1", self._port)

    def _run(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)

        async def serve():
            self._server = await asyncio.start_server(
                lambda r, w: _HTTP(r, w, self).serve(), "127.0.0.1", 0
            )
            self._port = self._server.sockets[0].getsockname()[1]
            self._started.set()
            # The close from another thread ends serve_forever with a
            # CancelledError; it is the shutdown, not a fault.
            try:
                async with self._server:
                    await self._server.serve_forever()
            except asyncio.CancelledError:
                pass

        self._loop.run_until_complete(serve())

    def __enter__(self):
        self._thread.start()
        self._started.wait(10)
        return self

    def __exit__(self, *a):
        if self._loop is not None:
            self._loop.call_soon_threadsafe(self._server.close)
        self._thread.join(timeout=5)
