"""The model side: one conversation, carried across prompts.

Everything here is arranged around keeping the request prefix byte-stable,
because a prefix cache can reuse a request only up to the first thing that
changed, and the order the model sees is: tool definitions, then the system
message, then the history. `tests/test_pai_cache.py` pins that; the two rules it
produces are:

* Per-invocation state (cwd, exit code) goes in the **user message**. Putting it
  in `instructions` would rewrite the system message on every `cd` and strand
  the entire conversation behind it.
* The toolset is settled before the first request and never grows. Adding a tool
  mid-conversation is worse than rewriting the system message -- tools serialize
  ahead of everything.

Moving to another repository is free: the file tools in `files` take paths
prefixed by *mount name*, never by mount path, so two agents built for different
workspaces serialize identically. That is what lets the agent be rebuilt
whenever the workspace changes without paying for it -- the model is told where
`repo/` currently points in the per-message context block, which is a user
message and therefore appended rather than rewritten.

pydantic-ai and the harness are imported inside functions, never at module
scope: `import pydantic_ai` alone costs ~500 ms, which is not something a shell
may spend before its first prompt.
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from .workspace import choose_root, root_from_env

#: `provider:model`, resolved by pydantic-ai. The provider half decides which
#: API key is read from the environment -- `deepseek:` wants `$DEEPSEEK_API_KEY`.
DEFAULT_MODEL = "deepseek:deepseek-v4-flash"

#: Static, and it has to stay that way -- see the module docstring. Nothing
#: derived from the session may appear here.
INSTRUCTIONS = """\
You are a command-line assistant embedded in a xonsh shell session.

Be terse. The user is at a prompt, not reading documentation. Prefer a concrete
command or a short answer over an explanation, and do not restate the question.

Each message begins with a <ctx/> element giving the working directory the
command was typed in, what the `repo/` mount currently points at, and the exit
status of the previous command. It describes that message only -- earlier
messages may have been sent from other directories, and both the directory and
the mount can change between messages.

You have three sets of tools:

* The file tools -- `list_files`, `read_file`, `search_files`, `edit_file`,
  `write_file`. Every path they take begins with a mount name: `repo/` is the
  user's current project, and `docs/` is the xonsh documentation shipped with
  this shell. Call `list_files` with no argument to see the mounts. These are
  quiet and need no permission, so prefer them to running commands.

  A result beginning `Error:` means the call did nothing at all. Read what it
  says and try something different; never report such a call as done.

  Consult `docs/` for the long tail the primer below does not cover -- a
  specific environment variable, an event name, how one builtin behaves. It is
  on local disk and costs the user nothing.
* The session tools -- `show_state` and `set_state`. `$NAME` is an environment
  variable and a bare `name` is a Python name, the same as at the prompt. These
  are quiet too, so look the shell's configuration up rather than guessing at
  it, and never run `print($X)` to find out what something is set to.
* `run_xonsh`, which runs code in the user's live session. Every call has to be
  approved, so reach for it when you actually need to run something or to look
  outside the workspace, not to read a file you could have read directly. Keep
  each call short and obvious; a long script is hard to approve. If a call is
  declined, ask what they would prefer instead of resending it.

  Say in `justification` what the command is for, in one sentence, and describe
  what it really does -- it is read side by side with the code by whoever
  approves it, so a justification that does not match the code is worse than
  none. Write it before you write the code: a command you cannot justify in a
  sentence is usually the wrong command.

  Whatever a command prints, the user has already watched it print, on their
  own terminal, as it ran. Never repeat it back to them. Answer the question
  they asked instead -- say what the output means, or what you will do next, or
  say nothing at all if the output already answered it. This is the one tool
  whose results they can see; a file you read is yours alone and worth
  summarising.

Xonsh is not bash. It is Python with shell syntax layered on, and the two modes
are decided per line. The syntax that trips people up:

    ls -la                  a bare command line runs as a subprocess
    x = 1 + 1               a line that parses as Python runs as Python
    $(cmd)                  run cmd, capture stdout as a string
    !(cmd)                  run cmd, return a CommandPipeline (has .returncode)
    $[cmd] / ![cmd]         run cmd uncaptured, output goes to the terminal
    @(expr)                 substitute a Python value into a command line;
                            a list becomes multiple arguments
    @$(cmd)                 run cmd and split its output into arguments
    $VAR                    an environment variable, a typed Python object --
                            $PATH is a list, not a colon-joined string
    ${...}                  the environment as a dict: ${...}.get("VAR", d)
    p"/some/path"           a Path literal; f-strings and r-strings work too

So: `@(files)` not `$files`, `$PATH.add(...)` not `PATH=$PATH:...`, and
`${...}.get("X")` to read a variable that may not exist. Prefer plain Python
where it is clearer -- it is all one language.\
"""


def context_header(
    cwd: str, exit_code: int | None, workspace: str | None = None
) -> str:
    """The per-message state block.

    Where everything that varies per invocation goes, and the reason the system
    message never has to change. `repo=` belongs here rather than in the tool
    descriptions for exactly that reason: the model needs to know what the mount
    points at, and the tool schemas must not.

    Deliberately small: it is repeated in every turn and stays in the history
    forever, so it is the one thing here that grows with conversation length.
    """
    status = "" if exit_code is None else f" exit={exit_code}"
    where = "" if workspace is None else f" repo={workspace!r}"
    return f"<ctx cwd={cwd!r}{where}{status}/>"


#: What the user typed to start the turn currently being answered, or `None`
#: between turns. Read by `tools.run_xonsh` so the overseer can see it.
#:
#: A module global rather than something threaded through the call, because
#: nothing between here and the tool has any business knowing about it: the
#: agent, pydantic-ai and the tool's own signature would all have to carry a
#: value none of them use. It is safe for the same reason the history is a plain
#: list -- one request at a time, which `worker.Worker` enforces rather than
#: hopes for. A `ContextVar` would be the tidier answer but not a more correct
#: one: pydantic-ai may run a synchronous tool on a thread of its choosing, and
#: which context that thread inherits is not ours to decide.
_asked: str | None = None


def asked() -> str | None:
    """The question being answered right now, as the user typed it."""
    return _asked


@contextmanager
def asking(text: str):
    """Mark `text` as the question being answered for the duration of a run.

    Restores rather than clears on the way out, so that this nests: it is not
    supposed to, but a version that clears would leave the outer turn looking
    like no turn at all, and the overseer would go back to judging blind at
    exactly the moment there was most to judge.
    """
    global _asked
    previous = _asked
    _asked = text
    try:
        yield
    finally:
        _asked = previous


@dataclass
class Session:
    """A conversation, plus the agent currently serving it.

    The agent is rebuilt whenever the model or workspace changes; the history
    survives that, because it belongs to the conversation rather than to any
    particular agent.
    """

    model: str = DEFAULT_MODEL
    history: list = field(default_factory=list)
    _agent: object | None = field(default=None, repr=False)
    _built_for: tuple[str, str | None] | None = field(default=None, repr=False)

    def root(self) -> Path:
        """The workspace the file tools are rooted at."""
        return root_from_env() or choose_root()

    def agent(self, root: Path):
        """The agent for `root`, rebuilt only when it would differ.

        Rebuilding is free as far as the prompt cache is concerned: the tools
        name mounts rather than paths, so two agents built for different
        workspaces serialize identically. The tool list is fixed here and never
        grows afterwards, which is the part that would cost.
        """
        key = (self.model, str(root))
        if self._agent is not None and self._built_for == key:
            return self._agent

        from pydantic_ai import Agent
        from pydantic_ai_harness.cache_stability import CacheStabilityMonitor

        from .files import bind
        from .state import TOOLS as STATE_TOOLS
        from .tools import run_xonsh

        self._agent = Agent(
            self.model,
            instructions=INSTRUCTIONS,
            capabilities=[CacheStabilityMonitor()],
            # Order is part of the request prefix. Adding to this list is fine;
            # reordering it silently costs every cached conversation, which is
            # why `bind` returns a fixed order rather than whatever it built.
            tools=[*bind(root), run_xonsh, *STATE_TOOLS],
        )
        self._built_for = key
        return self._agent

    def _question(self, text: str, cwd: str | None, exit_code: int | None):
        """The prompt and the agent to put it to, as one pair.

        Shared by both `ask` and `ask_async` so that the two cannot come to
        disagree about what a question looks like -- which would show up as a
        cache miss on every request rather than as anything obviously wrong.

        The context is read here, at the moment of asking. For the asynchronous
        path that matters: by the time the answer arrives the user may have
        `cd`'d somewhere else, and the question was still asked from here.
        """
        root = self.root()
        prompt = f"{context_header(cwd or os.getcwd(), exit_code, str(root))}\n{text}"
        return self.agent(root), prompt

    def ask(self, text: str, *, cwd: str | None = None, exit_code: int | None = None):
        """Put one question and wait for the answer.

        Returns the model's text. Raises whatever pydantic-ai raises -- the
        caller is closer to the user and knows how to say it.
        """
        from .progress import handler

        agent, prompt = self._question(text, cwd, exit_code)
        with asking(text):
            result = agent.run_sync(
                prompt,
                message_history=self.history or None,
                # Otherwise a request that reads four files before answering is
                # indistinguishable from one that hung.
                event_stream_handler=handler(),
            )
        self.history = result.all_messages()
        return result.output

    async def ask_async(
        self, text: str, *, cwd: str | None = None, exit_code: int | None = None
    ):
        """The same question, awaited rather than waited for.

        What the worker runs. `run_sync` is only this with a loop wrapped round
        it, so nothing is given up by preferring this -- and what is gained is
        that the shell's thread is not the one waiting.

        The history is assigned when the answer arrives, on the worker thread.
        Safe only because one request runs at a time: two would each start from
        the history as it was when they began and the later one would win,
        silently dropping the other's turns.
        """
        from .progress import handler

        agent, prompt = self._question(text, cwd, exit_code)
        with asking(text):
            result = await agent.run(
                prompt,
                message_history=self.history or None,
                event_stream_handler=handler(),
            )
        self.history = result.all_messages()
        return result.output

    def reset(self) -> None:
        """Forget the conversation, keep the agent."""
        self.history = []
