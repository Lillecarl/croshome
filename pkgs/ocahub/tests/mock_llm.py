"""
A scripted OpenAI-compatible chat server: the AI an opencode test runs against.

The point of the TUI checks is a real opencode loop with nobody behind
the model. This server stands in for the provider: it answers
`POST /v1/chat/completions` with a queued script of turns, streaming or
not, and records every request it saw. A check then asserts on the
record, the way a hub check asserts on its daemon's state.

A turn is one of:

    {"text": "done"}                     # a plain answer, and the loop ends
    {"tool_call": {"tool": "agent_send", # resolve the prefixed name from
                                         # the tools the client offered
                   "arguments": {"to": "tester", "message": "ping"}}}

The tool arrives in the request's `tools` under the name opencode
gives it -- the MCP server id is the prefix -- while the script spells
the tool the way the MCP server does, so the resolution happens here.
`requests` holds what came in, so a check can also read the tools list
to prove the ocahub tools were offered at all.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps(
                {"object": "list", "data": [{"id": t, "object": "model"} for t in self.server.models]}
            ).encode()
            self._send(200, "application/json", body)
            return
        self.send_error(404)

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            request = json.loads(body)
        except ValueError:
            request = {"_unparsed": body.decode(errors="replace")}
        self.server.requests.append(request)

        if self.server.turns:
            turn = self.server.turns.pop(0)
        else:
            turn = {"text": "(mock script exhausted)"}
        self.server.exhausted = not self.server.turns

        message, finish = _answer(turn, request)
        if request.get("stream"):
            self._stream(message, finish, request)
        else:
            payload = _body(request, message, finish, stream=False)
            self._send(200, "application/json", json.dumps(payload).encode())

    def _send(self, code, kind, body):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _stream(self, message, finish, request):
        # HTTP/1.1 with no length wants chunks or a close; the chat
        # stream is chunks. One chunk per event: the role, the body,
        # the finish, then the protocol's end mark.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def event(delta=None, the_finish=None):
            payload = _body(request, delta, the_finish, stream=True)
            chunk = b"data: " + json.dumps(payload).encode() + b"\n\n"
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()

        event({"role": "assistant", "content": ""})
        if "tool_calls" in message:
            event({"tool_calls": message["tool_calls"]})
        else:
            event({"content": message.get("content", "")})
        event(the_finish=finish)
        done = b"data: [DONE]\n\n"
        self.wfile.write(b"%x\r\n%s\r\n" % (len(done), done))
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def _answer(turn, request):
    """
    The assistant message and finish reason one scripted turn becomes.
    """
    if "tool_call" in turn:
        wanted = turn["tool_call"]["tool"]
        name = _offered_name(request, wanted)
        return (
            {
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {
                            "name": name,
                            "arguments": json.dumps(turn["tool_call"].get("arguments", {})),
                        },
                    }
                ]
            },
            "tool_calls",
        )
    return {"content": turn.get("text", "")}, "stop"


def _offered_name(request, wanted):
    """
    The name the client gave the tool the script calls, or the script's
    own spelling when the client offered nothing by that shape.
    """
    for tool in request.get("tools") or []:
        name = tool.get("function", {}).get("name", "")
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

    `turns` is the script, consumed front to back. `requests` is every
    parsed request body in arrival order; the tools list of the first
    one is how a check says the MCP tools were offered.
    """

    def __init__(self, turns):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.turns = list(turns)
        self.server.models = ["test"]
        self.server.requests = []
        self.server.exhausted = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        host, port = self.server.server_address
        return "http://%s:%d/v1" % (host, port)

    @property
    def requests(self):
        return self.server.requests

    @property
    def exhausted(self):
        return self.server.exhausted

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.server.shutdown()
        self.server.server_close()
