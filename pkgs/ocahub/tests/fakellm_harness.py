"""
The fakellm fixture: the mock provider is a process, its behavior rules.

fakellm (upstream, packaged in this repo) serves both wires the agents
speak, and takes answers from a YAML rule list the tests own as data.
Rules walk top to bottom and first match wins, so rule order is load
bearing: a rule set sits in reverse sequence -- the flow's last turn
first -- and every rule is keyed on text that only exists from its own
turn on. There are no turn numbers: opencode and claude both fire
small extra requests (a title generation) on the same wire, and a
turn-keyed rule answers the wrong call. Two matcher facts shape every
rule set:

- tool results and text blocks are flattened into the message text,
  so needles come from tool-result JSON and the mock's own earlier
  text;
- tool-call arguments are never seen, so a rule cannot key on what
  the model is about to call, only on what it has already been shown.
"""

import json
import os
import socket
import subprocess
import time
import urllib.request
from pathlib import Path


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Fakellm:
    """One `fakellm serve` per test, its rules as a Python list."""

    def __init__(self, work, log):
        self.work = Path(work)
        self.config_path = self.work / "fakellm.yaml"
        self.log_path = Path(log)
        self.rules = []
        self.port = _free_port()
        self._proc = None
        self._log = None

    @property
    def url(self):
        # The OpenAI-compatible base: opencode's provider config wants
        # the /v1 in it.
        return "http://127.0.0.1:%d/v1" % self.port

    @property
    def origin(self):
        # The Anthropic client appends /v1/messages itself, so it
        # takes the bare origin.
        return "http://127.0.0.1:%d" % self.port

    def rule(self, name, when, content=None, tool_calls=None, before=None):
        """
        Add one rule. `before` names an existing rule to sit ahead of:
        a staged rule wins matching order over everything staged
        before it, which is how a late-learned fact (an ask id) joins
        a rule list without rebuilding it.
        """
        respond = {}
        if content is not None:
            respond["content"] = content
        if tool_calls is not None:
            respond["tool_calls"] = tool_calls
        entry = {"name": name, "when": when, "respond": respond}
        if before is None:
            self.rules.append(entry)
        else:
            index = next(
                i for i, r in enumerate(self.rules) if r["name"] == before
            )
            self.rules.insert(index, entry)

    def write(self):
        self.work.mkdir(parents=True, exist_ok=True)
        # JSON is valid YAML: the rules need no yaml writer here.
        self.config_path.write_text(
            json.dumps({"rules": self.rules}, indent=2), encoding="utf-8"
        )

    def _admin(self, path):
        request = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (self.port, path), method="POST"
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read())

    def start(self, timeout=15.0):
        self.write()
        self._log = self.log_path.open("wb")
        self._proc = subprocess.Popen(
            [
                "fakellm",
                "serve",
                "--port",
                str(self.port),
                "--config",
                str(self.config_path),
            ],
            env={**os.environ, "FAKELLM_CONFIG": str(self.config_path)},
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self._admin("/_fakellm/reset")
                return
            except OSError:
                if self._proc.poll() is not None:
                    raise RuntimeError("fakellm died: see %s" % self.log_path)
                time.sleep(0.1)
        raise RuntimeError("fakellm never came up: see %s" % self.log_path)

    def reload(self):
        self.write()
        return self._admin("/_fakellm/reload")

    def stats(self):
        try:
            with urllib.request.urlopen(
                "http://127.0.0.1:%d/_fakellm/stats" % self.port, timeout=5
            ) as response:
                return json.loads(response.read())
        except OSError:
            return None

    def conversations(self):
        try:
            with urllib.request.urlopen(
                "http://127.0.0.1:%d/_fakellm/conversations" % self.port, timeout=5
            ) as response:
                return json.loads(response.read())
        except OSError:
            return None

    def stop(self):
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()
        if self._log is not None:
            self._log.close()
            self._log = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()


class LoggingProxy:
    """
    A pass-through in front of fakellm that dumps each request body's
    tail to a file. Claude's client and fakellm both keep their own
    view of the conversation; when a rule does not match, the only
    ground truth is what the wire carried. TEMPORARY -- a debugging
    instrument, not part of the fixture's contract.
    """

    def __init__(self, target_port, log):
        self.target_port = target_port
        self.log_path = Path(log)
        self.port = _free_port()
        self._server = None

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1" % self.port

    @property
    def origin(self):
        return "http://127.0.0.1:%d" % self.port

    async def start(self):
        import asyncio

        self._server = await asyncio.start_server(self._client, "127.0.0.1", self.port)

    async def _client(self, reader, writer):
        import asyncio

        tr, tw = await asyncio.open_connection("127.0.0.1", self.target_port)

        async def up():
            # The client keeps the connection alive and re-sends on it:
            # every request is read, logged, forwarded, one by one.
            try:
                while True:
                    data = b""
                    headers = {}
                    while True:
                        line = await reader.readline()
                        data += line
                        if line in (b"\r\n", b"\n", b""):
                            break
                        if b":" in line:
                            k, v = line.split(b":", 1)
                            headers[k.strip().lower()] = v.strip()
                    if not headers:
                        break
                    n = int(headers.get(b"content-length", b"0"))
                    body = await reader.readexactly(n) if n else b""
                    data += body
                    with self.log_path.open("ab") as f:
                        f.write(b"=== REQUEST ===\n" + body[-6000:] + b"\n")
                    tw.write(data)
                    await tw.drain()
            except Exception:
                pass
            finally:
                try:
                    tw.close()
                except Exception:
                    pass

        async def down():
            try:
                while chunk := await tr.read(65536):
                    writer.write(chunk)
                    await writer.drain()
            except Exception:
                pass
            finally:
                try:
                    writer.close()
                except Exception:
                    pass

        await asyncio.gather(
            asyncio.ensure_future(up()), asyncio.ensure_future(down())
        )

    def stop(self):
        if self._server is not None:
            self._server.close()
            self._server = None
