"""Wiring the model into xonsh. The only module here that imports xonsh.

Everything happens through `events.on_transform_command`, which hands over the
raw line *before* xonsh parses it. That is the whole reason this works: an alias
cannot take free text, because `ai what's my ip?` is a syntax error before the
alias is ever called, and `ai why did *that* fail | huh` parses but silently
globs and pipes. A transform sees the characters as typed.

The hook fires repeatedly until the source stops changing, so what it returns
must never itself start with the prefix -- a call to `__pai__.ask(...)` does not.

A question returns as soon as it has been handed to the worker, not when it has
been answered. So `ask` prints nothing: by the time there is anything to say,
the user is somewhere else entirely -- at a new prompt, halfway through typing,
or watching a build -- and `terminal.write` is what knows where that is.

The other hook is `on_ptk_create`, which stops the Python highlighter running
on a line that is prose. That is `highlight`'s business; all that happens here
is finding out that there is a prompt_toolkit shell to install it into.
"""

from __future__ import annotations

import sys

from .agent import Session
from .prefix import PREFIX, parse
from .terminal import write
from .worker import Busy, Worker

#: Overrides the `:` prefix. `,` is the other reasonable pick.
PREFIX_VAR = "XONTRIB_PAI_PREFIX"

#: Overrides `agent.DEFAULT_MODEL`, as a pydantic-ai `provider:model` string.
MODEL_VAR = "XONTRIB_PAI_MODEL"


def drawn_by_prompt_toolkit() -> bool:
    """Is this xonsh drawing its prompt with prompt_toolkit, or going to be?

    Two answers, because there are two moments this gets asked from and only
    one of them has a shell to ask.

    Where there is one, `prompter` is the tell and it is cheap:
    `PromptToolkitShell.__init__` builds one, and neither the readline shell
    nor the dumb shell -- which is the readline shell, whatever `$SHELL_TYPE`
    says -- has anything of the sort.

    Where there is not, which is every rc file, xonsh sources those *before*
    building the shell. That is why the xontribs wait on `on_ptk_create`
    instead of reaching for it. So ask xonsh the question it is about to answer
    itself: `choose_shell_type` is the same resolution it will run in a
    moment, including `best`, including `$TERM=dumb` beating `$SHELL_TYPE`, and
    including falling back to readline when prompt_toolkit cannot be imported.
    Reading `$SHELL_TYPE` here instead would get all three wrong.
    """
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return False

    shell = getattr(getattr(XSH, "shell", None), "shell", None)
    if shell is not None:
        return hasattr(shell, "prompter")

    try:
        from xonsh.shell import Shell

        return Shell.choose_shell_type(env=getattr(XSH, "env", None)) == (
            "prompt_toolkit"
        )
    except Exception:  # noqa: BLE001 - a guess that fails must not stop a load
        return False


def env_get(name: str, default=None):
    """One xonsh environment variable, or `default` where there is no xonsh."""
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return default
    env = getattr(XSH, "env", None)
    return default if env is None else env.get(name, default)


class Installation:
    """What `xontrib load pai` hands back, and `xontrib unload pai` undoes."""

    def __init__(self) -> None:
        self.session = Session(model=str(env_get(MODEL_VAR) or Session.model))
        self.worker = Worker()
        self._hooks: list = []

    @property
    def prefix(self) -> str:
        # Read per line rather than cached, so it can be changed by eye.
        return str(env_get(PREFIX_VAR) or PREFIX)

    @property
    def active(self) -> bool:
        return bool(self._hooks)

    def dispatch(self, command: str, text: str) -> None:
        """Run one parsed request. Called from the transformed command line."""
        if command:
            self.run_command(command, text)
        else:
            self.ask(text)

    def ask(self, text: str) -> None:
        """Put a question and hand the prompt straight back.

        The answer arrives whenever it arrives, printed above whatever the user
        is typing by then -- or plainly, if they are running something. Which
        means this returns before there is anything to say, and everything
        below happens on the worker thread.
        """
        import os

        cwd = os.getcwd()
        exit_code = env_get("LAST_RETURN_CODE")

        async def run():
            return await self.session.ask_async(text, cwd=cwd, exit_code=exit_code)

        def finished(answer, exception) -> None:
            if exception is not None:
                # A missing API key, a rate limit and a network blip all land
                # here and all mean the same thing to someone at a prompt: it
                # did not work, and the shell is still fine.
                write(f"pai: {type(exception).__name__}: {exception}\n")
            elif answer is not None:
                # Laid out here rather than by the model: asking for plain text
                # in the instructions does not work, and would spend prefix on
                # something a hundred lines of `render` does properly.
                from .render import render

                write(f"{render(answer)}\n")
            # Neither: cancelled, which the user asked for and already knows.

        try:
            self.worker.submit(run, finished)
        except Busy:
            print(
                "pai: still working on the last question. `:cancel` to stop it.",
                file=sys.stderr,
            )

    def run_command(self, command: str, text: str) -> None:
        handler = COMMANDS.get(command)
        if handler is None:
            known = ", ".join(sorted(COMMANDS))
            print(
                f"pai: unknown command {command!r}; try one of: {known}",
                file=sys.stderr,
            )
            return
        handler(self, text)

    def uninstall(self) -> None:
        for event, handler in self._hooks:
            event.discard(handler)
        self._hooks.clear()
        # The thread is a daemon and would not hold the shell open, but a
        # request still running after `xontrib unload pai` would go on writing
        # to the terminal of a shell that has unloaded us.
        self.worker.shutdown()


def _cmd_cancel(installation: Installation, _text: str) -> None:
    """Stop the request in flight."""
    if installation.worker.cancel():
        print("pai: cancelled")
    else:
        print("pai: nothing to cancel")


def _cmd_reset(installation: Installation, _text: str) -> None:
    """Forget the conversation so far."""
    installation.session.reset()
    print("pai: conversation reset")


def _cmd_model(installation: Installation, text: str) -> None:
    """Show or change the model."""
    if not text:
        print(installation.session.model)
        return
    installation.session.model = text
    # The agent is rebuilt lazily on the next request; the history survives.
    print(f"pai: model set to {text}")


def _cmd_root(installation: Installation, _text: str) -> None:
    """Show which directory the file tools are rooted at."""
    root = installation.session.root()
    if root is None:
        print(
            "pai: no workspace root, so file tools are off. There is no "
            "directory here that both holds your work and excludes your "
            "credentials -- cd into a repository, or set $XONTRIB_PAI_ROOT.",
            file=sys.stderr,
        )
        return
    print(root)


def _cmd_help(_installation: Installation, _text: str) -> None:
    """List these commands."""
    for name, handler in sorted(COMMANDS.items()):
        print(f"  {name:8} {(handler.__doc__ or '').strip()}")


#: Registration order is fixed and alphabetical on purpose -- see
#: `tests/test_pai_cache.py::test_tool_order_follows_registration_order`. These
#: are shell commands rather than model tools, but the habit is the point.
COMMANDS = {
    "cancel": _cmd_cancel,
    "help": _cmd_help,
    "model": _cmd_model,
    "reset": _cmd_reset,
    "root": _cmd_root,
}

_installation: Installation | None = None


def setup() -> Installation:
    """Install the prefix hook into the running shell.

    Idempotent: loading twice must not register a second transform, which would
    make every request run twice.

    Refuses without prompt_toolkit, and refusing is the honest answer rather
    than a limitation. Everything past the prefix hook is built on the prompt
    being suspendable: `terminal.interact` hands a command to prompt_toolkit's
    own loop through `run_in_terminal`, which is what erases the prompt,
    detaches the keyboard and gets the command onto the main thread -- where,
    incidentally, it is the only place a SIGINT handler may be installed, so it
    is also what makes Ctrl+C work. None of that has an equivalent in the
    readline shell. What a `:` line would get there is the fallback path, and
    the fallback path is where commands run without an interruptible terminal.

    Said once, plainly, and not raised: this is reached from an rc file, and a
    traceback on every shell start is a worse answer than a sentence.
    """
    from xonsh.built_ins import XSH
    from xonsh.events import events

    global _installation
    if _installation is not None and _installation.active:
        return _installation

    if not drawn_by_prompt_toolkit():
        print(
            "xontrib-pai: needs the prompt_toolkit shell, which this xonsh is "
            "not using (a readline or dumb shell -- check $SHELL_TYPE and "
            "$TERM). Not loaded.",
            file=sys.stderr,
        )
        return Installation()

    installation = Installation()

    @events.on_transform_command
    def _transform(cmd, **_):
        line = cmd.rstrip("\n")
        request = parse(line, installation.prefix)
        if request is None:
            return cmd
        return f"__pai__.dispatch({request.command!r}, {request.text!r})\n"

    @events.on_ptk_create
    def _on_ptk_create(prompter, **_):
        # Imported here rather than at module scope so that `xontrib load pai`
        # in a readline shell -- or a non-interactive one -- does not pay for
        # prompt_toolkit. By the time this fires it has been imported anyway.
        from .highlight import install

        install(prompter, lambda: installation.prefix)

    @events.on_exit
    def _stop(**_):
        # Nothing waits for the answer to a question asked by a shell that is
        # closing, and a request still writing to the terminal while xonsh
        # tears it down has nowhere good to write.
        installation.worker.shutdown()

    installation._hooks = [
        (events.on_transform_command, _transform),
        (events.on_ptk_create, _on_ptk_create),
        (events.on_exit, _stop),
    ]
    XSH.ctx["__pai__"] = installation
    _installation = installation
    return installation
