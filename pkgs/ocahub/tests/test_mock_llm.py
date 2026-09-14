"""
The mock provider judged on its own: the wire the client sees.

The TUI checks stand on this server, so its two protocols -- the
streamed one the AI SDK speaks and the plain one nothing speaks but a
debugger -- are judged here before anything runs a real opencode.
"""

import http.client
import json

import pytest

from mock_llm import MockLLM

#: One tool offered, the least that marks a request as the agent loop
#: and not one of the small side calls.
TOOLS = [{"type": "function", "function": {"name": "bash"}}]


def post(llm, payload):
    host, port = llm.server_address
    connection = http.client.HTTPConnection(host, port, timeout=10)
    connection.request(
        "POST",
        "/v1/chat/completions",
        body=json.dumps(payload),
        headers={"Content-Type": "application/json"},
    )
    answer = connection.getresponse()
    return answer


def sse_events(raw):
    "The JSON events of an SSE body; the [DONE] mark is not an event."
    return [
        json.loads(line[6:])
        for line in raw.splitlines()
        if line.startswith("data: ") and line != "data: [DONE]"
    ]


def test_plain_answer_is_json_and_ends_the_loop():
    with MockLLM({"test": [{"text": "hello"}]}) as llm:
        answer = post(llm, {"model": "test", "stream": False, "tools": TOOLS})
        assert answer.status == 200
        body = json.loads(answer.read())
        choice = body["choices"][0]
        assert choice["message"]["content"] == "hello"
        assert choice["finish_reason"] == "stop"


def test_stream_is_sse_with_role_body_and_finish():
    with MockLLM({"test": [{"text": "hello"}]}) as llm:
        answer = post(llm, {"model": "test", "stream": True, "tools": TOOLS})
        assert answer.getheader("Content-Type") == "text/event-stream"
        raw = answer.read().decode()
        events = sse_events(raw)
        assert len(events) == 3
        assert events[0]["choices"][0]["delta"] == {"role": "assistant", "content": ""}
        assert events[1]["choices"][0]["delta"] == {"content": "hello"}
        assert events[2]["choices"][0]["finish_reason"] == "stop"
        assert "data: [DONE]" in raw


def test_tool_call_resolves_the_offered_name():
    turns = [{"tool_call": {"tool": "agent_send", "arguments": {"to": "x"}}}]
    with MockLLM({"test": turns}) as llm:
        offered = {
            "model": "test",
            "stream": False,
            "tools": [{"type": "function", "function": {"name": "ocahub_agent_send"}}],
        }
        answer = post(llm, offered)
        call = json.loads(answer.read())["choices"][0]["message"]["tool_calls"][0]
        assert call["function"]["name"] == "ocahub_agent_send"
        assert call["function"]["arguments"] == '{"to": "x"}'


def test_models_are_served_from_separate_scripts():
    with MockLLM({"a": [{"text": "from a"}], "b": [{"text": "from b"}]}) as llm:
        answer = post(llm, {"model": "a", "stream": False, "tools": TOOLS})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "from a"
        answer = post(llm, {"model": "b", "stream": False, "tools": TOOLS})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "from b"


def test_small_calls_take_the_canned_answer_and_not_the_script():
    with MockLLM({"test": [{"text": "for the loop"}]}, small_answer="title") as llm:
        answer = post(llm, {"model": "test", "stream": False})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "title"
        answer = post(llm, {"model": "test", "stream": False, "tools": TOOLS})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "for the loop"


def test_exhausted_script_still_answers():
    with MockLLM({"test": [{"text": "only"}]}) as llm:
        post(llm, {"model": "test", "stream": False, "tools": TOOLS})
        answer = post(llm, {"model": "test", "stream": False, "tools": TOOLS})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "(mock script exhausted)"
        assert llm.exhausted


def test_placeholder_substitutes_the_ask_id_from_the_tool_result():
    turns = [
        {
            "tool_call": {
                "tool": "agent_reply",
                "arguments": {"reply_to": "$ask_id", "message": "answered"},
            }
        }
    ]
    with MockLLM({"test": turns}) as llm:
        inbox_result = json.dumps(
            {
                "you": {"name": "beta", "session": "s1"},
                "messages": [{"id": "abc123", "kind": "ask", "from": "alpha@s0"}],
            }
        )
        offered = {
            "model": "test",
            "stream": False,
            "tools": [{"type": "function", "function": {"name": "ocahub_agent_reply"}}],
            "messages": [
                {"role": "user", "content": "check the inbox"},
                {"role": "assistant", "tool_calls": [], "content": None},
                {"role": "tool", "tool_call_id": "call_1", "content": inbox_result},
            ],
        }
        answer = post(llm, offered)
        call = json.loads(answer.read())["choices"][0]["message"]["tool_calls"][0]
        arguments = json.loads(call["function"]["arguments"])
        assert arguments["reply_to"] == "abc123"
        assert arguments["message"] == "answered"


def test_models_endpoint():
    with MockLLM({}) as llm:
        connection = http.client.HTTPConnection("127.0.0.1", llm.port, timeout=10)
        connection.request("GET", "/v1/models")
        answer = connection.getresponse()
        assert answer.status == 200
        assert json.loads(answer.read())["data"] == [{"id": "test", "object": "model"}]


@pytest.mark.parametrize("stream", [False, True])
def test_finish_reason_of_a_tool_turn(stream):
    turns = [{"tool_call": {"tool": "agent_send", "arguments": {}}}]
    with MockLLM({"test": turns}) as llm:
        answer = post(llm, {"model": "test", "stream": stream, "tools": TOOLS})
        if stream:
            raw = answer.read().decode()
            events = sse_events(raw)
            assert events[-1]["choices"][0]["finish_reason"] == "tool_calls"
        else:
            assert json.loads(answer.read())["choices"][0]["finish_reason"] == "tool_calls"


# The Anthropic messages route, which claude-code speaks: flat tool
# names, content blocks, and an SSE sequence of named events rather
# than chat chunks.
A_TOOLS = [{"name": "Bash", "input_schema": {"type": "object"}}]


def post_messages(llm, payload):
    host, port = llm.server_address
    connection = http.client.HTTPConnection(host, port, timeout=10)
    connection.request(
        "POST",
        "/v1/messages",
        body=json.dumps(payload),
        headers={"Content-Type": "application/json"},
    )
    return connection.getresponse()


def test_anthropic_text_streams_as_the_event_sequence():
    with MockLLM({"claude": [{"text": "hi"}]}) as llm:
        answer = post_messages(
            llm, {"model": "claude", "stream": True, "tools": A_TOOLS, "messages": []}
        )
        assert answer.getheader("Content-Type") == "text/event-stream"
        events = sse_events(answer.read().decode())
        assert [e["type"] for e in events] == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ]
        assert events[2]["delta"] == {"type": "text_delta", "text": "hi"}
        assert events[4]["delta"]["stop_reason"] == "end_turn"


def test_anthropic_tool_call_resolves_the_flat_name():
    turns = [{"tool_call": {"tool": "agent_reply", "arguments": {"message": "x"}}}]
    with MockLLM({"claude": turns}) as llm:
        answer = post_messages(
            llm,
            {
                "model": "claude",
                "stream": False,
                "tools": [{"name": "mcp__ocahub__agent_reply", "input_schema": {}}],
                "messages": [],
            },
        )
        body = json.loads(answer.read())
        block = body["content"][0]
        assert body["stop_reason"] == "tool_use"
        assert block["type"] == "tool_use"
        assert block["name"] == "mcp__ocahub__agent_reply"


def test_anthropic_substitutes_the_ask_id_from_plain_text():
    """
    The wake a monitor's completion delivers is a plain user text
    carrying the hub's delivery line -- and its id is what a scripted
    reply answers.
    """
    turns = [
        {
            "tool_call": {
                "tool": "agent_reply",
                "arguments": {"reply_to": "$ask_id", "message": "answered"},
            }
        }
    ]
    with MockLLM({"claude": turns}) as llm:
        answer = post_messages(
            llm,
            {
                "model": "claude",
                "stream": False,
                "tools": A_TOOLS,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    {"id": "ask_42", "kind": "ask", "payload": "what?"}
                                ),
                            }
                        ],
                    }
                ],
            },
        )
        block = json.loads(answer.read())["content"][0]
        assert block["input"]["reply_to"] == "ask_42"


def test_anthropic_substitutes_from_a_tool_result_block():
    turns = [
        {
            "tool_call": {
                "tool": "agent_reply",
                "arguments": {"reply_to": "$ask_id", "message": "answered"},
            }
        }
    ]
    with MockLLM({"claude": turns}) as llm:
        answer = post_messages(
            llm,
            {
                "model": "claude",
                "stream": False,
                "tools": A_TOOLS,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "toolu_1",
                                "content": json.dumps(
                                    {"messages": [{"id": "ask_7", "kind": "ask"}]}
                                ),
                            }
                        ],
                    }
                ],
            },
        )
        block = json.loads(answer.read())["content"][0]
        assert block["input"]["reply_to"] == "ask_7"
