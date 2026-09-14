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


def post(llm, payload):
    host, port = llm.server.server_address
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
    with MockLLM([{"text": "hello"}]) as llm:
        answer = post(llm, {"model": "test", "stream": False})
        assert answer.status == 200
        body = json.loads(answer.read())
        choice = body["choices"][0]
        assert choice["message"]["content"] == "hello"
        assert choice["finish_reason"] == "stop"


def test_stream_is_sse_with_role_body_and_finish():
    with MockLLM([{"text": "hello"}]) as llm:
        answer = post(llm, {"model": "test", "stream": True})
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
    with MockLLM(turns) as llm:
        offered = {
            "model": "test",
            "stream": False,
            "tools": [{"type": "function", "function": {"name": "ocahub_agent_send"}}],
        }
        answer = post(llm, offered)
        call = json.loads(answer.read())["choices"][0]["message"]["tool_calls"][0]
        assert call["function"]["name"] == "ocahub_agent_send"
        assert call["function"]["arguments"] == '{"to": "x"}'


def test_requests_are_recorded_in_order():
    with MockLLM([{"text": "a"}, {"text": "b"}]) as llm:
        post(llm, {"model": "test", "stream": False, "tools": []})
        post(llm, {"model": "test", "stream": False})
        assert [r.get("model") for r in llm.requests] == ["test", "test"]


def test_exhausted_script_still_answers():
    with MockLLM([{"text": "only"}]) as llm:
        post(llm, {"model": "test", "stream": False})
        answer = post(llm, {"model": "test", "stream": False})
        assert json.loads(answer.read())["choices"][0]["message"]["content"] == "(mock script exhausted)"
        assert llm.exhausted


def test_models_endpoint():
    with MockLLM([]) as llm:
        host, port = llm.server.server_address
        connection = http.client.HTTPConnection(host, port, timeout=10)
        connection.request("GET", "/v1/models")
        answer = connection.getresponse()
        assert answer.status == 200
        assert json.loads(answer.read())["data"] == [{"id": "test", "object": "model"}]


@pytest.mark.parametrize("stream", [False, True])
def test_finish_reason_of_a_tool_turn(stream):
    turns = [{"tool_call": {"tool": "agent_send", "arguments": {}}}]
    with MockLLM(turns) as llm:
        answer = post(llm, {"model": "test", "stream": stream})
        if stream:
            raw = answer.read().decode()
            events = sse_events(raw)
            assert events[-1]["choices"][0]["finish_reason"] == "tool_calls"
        else:
            assert json.loads(answer.read())["choices"][0]["finish_reason"] == "tool_calls"
