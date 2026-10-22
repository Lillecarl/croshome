"""Helix editing on xonsh's prompt: ptkhx's bindings, put where xonsh reads them.

ptkhx (pyterm's `ptkhx/`) holds the editor and its prompt_toolkit bindings,
and its oracle check holds the keymap to real Helix. This module is what is
xonsh's about them:

* Enter defers to xonsh's own multi-line parser.
* Escape closes a completion menu first when `$COMPLETIONS_CONFIRM` says so.
* Ctrl-R turns the line into a filter over xonsh's history.
* The CSI-u Enter of the kitty keyboard protocol, when the terminal answered.
* `{helix_mode}` and `{helix_pending}`, prompt fields read at render time.
* The selection colour, from the terminal's own background.

The bindings go into the registry xonsh hands to `prompt()` last, which is
what puts them at the end of the merge order, where ties are won.
"""

from __future__ import annotations

import sys

from prompt_toolkit.filters import Condition
from prompt_toolkit.key_binding import KeyBindings, merge_key_bindings
from prompt_toolkit.keys import Keys
from prompt_toolkit.layout.controls import BufferControl
from ptkhx import Mode
from ptkhx.bindings import (
    FALLBACK_SELECTION_STYLE,
    SECONDARY_CURSOR_STYLE,
    TIMEOUTLEN,
    HelixBindings,
    SelectionProcessor,
)

from .terminal import query_background, shifted

#: xonsh's own knob for the key-sequence timeout. Set it and we keep out of
#: the way.
TIMEOUTLEN_VAR = "XONSH_PTK_TIMEOUTLEN"

#: Overrides the selection style outright. Any prompt_toolkit style string --
#: `bg:#402030`, `underline`, or `class:selected` to go back to prompt_toolkit's
#: reverse video. Re-read once per prompt, so it can be tuned by eye.
SELECTION_STYLE_VAR = "XONTRIB_HELIX_SELECTION_STYLE"

#: Overrides how every cursor but the primary is drawn. Same values as
#: `$XONTRIB_HELIX_SELECTION_STYLE`.
SECONDARY_CURSOR_STYLE_VAR = "XONTRIB_HELIX_SECONDARY_CURSOR_STYLE"


def _env_get(name: str, default=None):
    """One xonsh environment variable, or `default` where there is no xonsh."""
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return default
    env = getattr(XSH, "env", None)
    return default if env is None else env.get(name, default)


def _completions_confirm() -> bool:
    """`$COMPLETIONS_CONFIRM`, or True where there is no xonsh to ask."""
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return True
    env = getattr(XSH, "env", None)
    return True if env is None else bool(env.get("COMPLETIONS_CONFIRM", False))


def _carriage_return(buf, app) -> None:
    """Submit the line, deferring to xonsh's multi-line parser when present.

    xonsh decides whether Enter runs the command or opens a continuation line by
    parsing what has been typed so far -- an open paren, a trailing colon, a
    line continuation. Reimplementing that would guarantee drift, so call it.
    """
    if buf.multiline():
        try:
            from xonsh.shells.ptk_shell.key_bindings import carriage_return
        except ImportError:
            buf.newline()
            return
        carriage_return(buf, app)
    else:
        buf.validate_and_handle()


class HelixMode(HelixBindings):
    """Helix editing installed on one xonsh prompt_toolkit session."""

    def __init__(self, session, *, initial_mode: Mode = Mode.INSERT):
        self.session = session
        #: Live history-search state, or None. See `_open_histsearch`.
        self.histsearch: dict | None = None
        super().__init__(
            initial_mode=initial_mode,
            accept=_carriage_return,
            confirm_completion=_completions_confirm,
            csi_u_enter=_env_get("ANYXONSH_KEYBOARD") == "kitty",
        )
        self.key_bindings = merge_key_bindings([self.key_bindings, self._histsearch_bindings()])
        self.apply_timeouts()

    @property
    def _buffer(self):
        return self.session.default_buffer

    @property
    def editor(self):
        return self.editor_for(self._buffer)

    @property
    def mode(self) -> Mode:
        return self.editor.mode

    def apply_timeouts(self) -> None:
        """Put the key-sequence timeout back on the application.

        Every prompt, not once. xonsh's `singleline` assigns `app.timeoutlen`
        from `$XONSH_PTK_TIMEOUTLEN` -- default 1.0 -- at the top of each
        prompt, so anything set when the session was created is gone before
        the first key is read. Does nothing when that variable is set: someone
        who reached for xonsh's own knob has said what they want.
        """
        if _env_get(TIMEOUTLEN_VAR) is not None:
            return
        self.session.app.timeoutlen = TIMEOUTLEN

    def reset_prompt(self) -> None:
        """Start a fresh prompt. An open history search goes with the line."""
        self.reset(self._buffer)
        self.histsearch = None

    def install_renderer(self) -> bool:
        """Add the selection painter to this session's buffer control.

        The control is a local in `PromptSession._create_layout`, so it is found
        by walking the layout. Returns False if it could not be found, in which
        case editing still works and only the highlight is missing. A painter
        an earlier `HelixMode` left is replaced: it would paint from editors
        that no longer receive keys.
        """
        for control in self.session.app.layout.find_all_controls():
            if isinstance(control, BufferControl) and control.buffer is self._buffer:
                processors = control.input_processors
                if processors is None:
                    processors = control.input_processors = []
                mine = self.processor()
                for i, existing in enumerate(processors):
                    if isinstance(existing, SelectionProcessor):
                        processors[i] = mine
                        break
                else:
                    processors.append(mine)
                return True
        return False

    def copy_into(self, bindings: KeyBindings) -> None:
        """Add every binding to xonsh's own registry, which `prompt()` merges last."""
        for binding in self.key_bindings.bindings:
            bindings.add(
                *binding.keys,
                filter=binding.filter,
                eager=binding.eager,
                is_global=binding.is_global,
                save_before=binding.save_before,
                record_in_macro=binding.record_in_macro,
            )(binding.handler)

    # ------------------------------------------------------------ histsearch --

    def histsearch_active(self) -> bool:
        return self.histsearch is not None

    def before_escape(self, event) -> bool:
        if self.histsearch_active():
            self._close_histsearch(event, accept=False)
            return True
        return super().before_escape(event)

    def _histsearch_bindings(self) -> KeyBindings:
        """Ctrl-R, and Enter while it is open.

        Ctrl-R and not `/`, which keeps its Helix meaning. Bound in both modes:
        reflexes reach for Ctrl-R mid-typing. Ours replaces prompt_toolkit's own
        reverse search outright.
        """
        bindings = KeyBindings()
        enabled = Condition(lambda: self.enabled)
        searching = Condition(lambda: self.enabled and self.histsearch_active())

        @bindings.add(Keys.ControlR, filter=enabled)
        def _histsearch_open(event):
            if not self.histsearch_active():
                self._open_histsearch(event)

        # While search is open, Enter accepts: the highlighted alternative
        # replaces the line, or the bare query when nothing matched. The line
        # stays editable in insert mode; the next Enter runs it.
        for key in (Keys.ControlM, Keys.ControlJ):

            @bindings.add(key, filter=searching)
            def _histsearch_accept(event):
                self._close_histsearch(event, accept=True)

        return bindings

    def _open_histsearch(self, event) -> None:
        """Turn the command line into a filter over this shell's history.

        The line is cleared -- an empty query means "show me where I have been"
        rather than "match against what little was here" -- the completer is
        swapped for the history one, and insert mode takes over so typing flows
        straight into the query. The pre-search line comes back on Escape.
        """
        from .search import HistorySearchCompleter

        buf = self._buffer
        self.histsearch = {
            "text": buf.text,
            "cursor": buf.cursor_position,
            "completer": buf.completer,
            # The buffer's own value, not the session's: xonsh passes the
            # session a bare bool, which prompt_toolkit never calls but a
            # buffer must be.
            "typing": buf.complete_while_typing,
        }
        buf.text = ""
        buf.cursor_position = 0
        buf.completer = HistorySearchCompleter()
        buf.complete_while_typing = Condition(lambda: True)
        self.editor.mode = Mode.INSERT
        self.adopt(buf)
        buf.start_completion()

    def _close_histsearch(self, event, *, accept: bool) -> None:
        """Leave history search, restoring on cancel and keeping on accept."""
        st = self.histsearch
        if st is None:
            return
        self.histsearch = None
        buf = event.current_buffer

        buf.completer = st["completer"]
        buf.complete_while_typing = st["typing"]

        chosen = None
        if accept:
            state = buf.complete_state
            # `current_completion` is None until an arrow key has moved over
            # the menu, though entry 0 already draws highlighted. Accepting
            # means: the arrowed entry, else the first one, else the query.
            if state is not None:
                current = state.current_completion
                if current is not None:
                    chosen = current.text
                elif state.completions:
                    chosen = state.completions[0].text

        if accept and (chosen is not None or buf.text):
            final = chosen if chosen is not None else buf.text
            buf.cancel_completion()
            buf.text = final
            buf.cursor_position = len(final)
            self.adopt(buf)
        else:
            # Escape, or accept on an empty query: the line you came with.
            buf.cancel_completion()
            buf.text = st["text"]
            buf.cursor_position = min(st["cursor"], len(buf.text))
            self.adopt(buf)
            self.editor.mode = Mode.NORMAL


class Installation:
    """Handle on a Helix installation in a running xonsh.

    What `xontrib load helix` puts in the shell namespace as `__helix__`, and
    what `xontrib unload helix` calls `uninstall()` on.

    `helix` is `None` until the first prompt is created, because the
    prompt_toolkit session does not exist before then -- `setup()` is called
    while the xontrib loads, which is earlier.
    """

    def __init__(self):
        self.helix: HelixMode | None = None
        self._hooks: list[tuple[object, object]] = []
        #: The terminal's own background, from OSC 11, or `None` if it declined
        #: to answer. Asked once per shell.
        self.background: tuple[int, int, int] | None = None

    @property
    def mode_label(self) -> str:
        return self.helix.mode.label if self.helix is not None else ""

    @property
    def pending_label(self) -> str:
        """The half-typed command, with a leading space, or nothing at all.

        The space belongs to the value rather than to the prompt template
        because a prompt field cannot ask to be skipped when it is empty.
        """
        if self.helix is None:
            return ""
        if self.helix.histsearch_active():
            return " history"
        if not self.helix.editor.pending:
            return ""
        return f" {self.helix.editor.pending}"

    def selection_style(self) -> str:
        """The style string to paint over selections, in precedence order."""
        override = _env_get(SELECTION_STYLE_VAR)
        if override:
            return str(override)
        if self.background is not None:
            return f"bg:{shifted(self.background)}"
        return FALLBACK_SELECTION_STYLE

    def secondary_cursor_style(self) -> str:
        """The style string to paint over cursors other than the primary."""
        override = _env_get(SECONDARY_CURSOR_STYLE_VAR)
        return str(override) if override else SECONDARY_CURSOR_STYLE

    @property
    def active(self) -> bool:
        return bool(self._hooks)

    def uninstall(self) -> None:
        """Detach the hooks and switch off the bindings of any live session.

        Both halves are needed. Dropping only the hooks would leave editing
        working while `on_pre_prompt` no longer reset it, so undo history and
        half-typed commands would leak between prompts.
        """
        for event, handler in self._hooks:
            event.discard(handler)
        self._hooks.clear()
        if self.helix is not None:
            self.helix.enabled = False
            self.helix = None


class _LiveField:
    """A prompt field whose value is read when the prompt is *drawn*.

    `PromptFields.pick` calls a field once per prompt and caches the string it
    returned, so a plain `lambda` is stuck on whatever was true when the line
    began. `pick` caches this object instead, and `_format_value` calls
    `format()` on it at each render, which is where the read happens.

    Not callable, deliberately: `pick` calls anything callable and caches the
    result, which is the behaviour being avoided.
    """

    #: Attribute of `Installation` to read at render time.
    source = ""

    def __init__(self, installation: Installation):
        self._installation = installation

    @property
    def _value(self) -> str:
        return getattr(self._installation, self.source)

    def __format__(self, spec: str) -> str:
        return format(self._value, spec)

    def __str__(self) -> str:
        return self._value

    def __repr__(self) -> str:
        return f"<{type(self).__name__} {self._value!r}>"


class ModeField(_LiveField):
    """The `{helix_mode}` prompt field: `NOR`, `INS` or `SEL`."""

    source = "mode_label"


class PendingField(_LiveField):
    """The `{helix_pending}` prompt field: the command being typed.

    A count and a menu prefix while one is half-entered, and the regex while
    `s`, `S`, `K` or `Alt-K` is reading one -- the only place that regex shows.
    Empty unless there is something to say, with its own leading space.
    """

    source = "pending_label"


#: The one live installation in this process, or `None`. See `setup`.
_installation: Installation | None = None


def drawn_by_prompt_toolkit() -> bool:
    """Is this xonsh drawing its prompt with prompt_toolkit, or going to be?

    Where there is a shell, `prompter` is the tell: `PromptToolkitShell`
    builds one, and the readline and dumb shells have nothing of the sort.
    Where there is not, which is every rc file, ask xonsh the question it is
    about to answer itself: `choose_shell_type`.
    """
    from xonsh.built_ins import XSH

    shell = getattr(getattr(XSH, "shell", None), "shell", None)
    if shell is not None:
        return hasattr(shell, "prompter")

    try:
        from xonsh.shell import Shell

        return Shell.choose_shell_type(env=getattr(XSH, "env", None)) == "prompt_toolkit"
    except Exception:  # noqa: BLE001 - a guess that fails must not stop a load
        return False


def setup(*, initial_mode: Mode = Mode.INSERT) -> Installation:
    """Install Helix editing into the running xonsh shell.

    Idempotent: a second `on_ptk_create` handler would build a second
    `HelixMode` on the same session, whose bindings win every tie while the
    first one keeps the selection painter.

    Registers `{helix_mode}` and `{helix_pending}` prompt fields but puts
    neither in any prompt: a textual indicator forces
    `$UPDATE_PROMPT_ON_KEYPRESS`, and spending that is the caller's decision.

    Refuses without prompt_toolkit, and says so once rather than raising: this
    is reached from an rc file.
    """
    from xonsh.built_ins import XSH
    from xonsh.events import events

    global _installation
    if _installation is not None and _installation.active:
        return _installation

    if not drawn_by_prompt_toolkit():
        print(
            "xontrib-helix: needs the prompt_toolkit shell, which this xonsh "
            "is not using (a readline or dumb shell -- check $SHELL_TYPE and "
            "$TERM). Not loaded.",
            file=sys.stderr,
        )
        return Installation()

    installation = Installation()
    # Before prompt_toolkit owns the terminal, and only for an interactive
    # shell: `anyxonsh -c` from a terminal would otherwise write an escape
    # sequence into the command's own output and wait out the timeout.
    if _env_get("XONSH_INTERACTIVE", False):
        installation.background = query_background()

    @events.on_ptk_create
    def _on_ptk_create(prompter, history, completer, bindings, **_):
        helix = HelixMode(prompter, initial_mode=initial_mode)
        helix.copy_into(bindings)
        if not helix.install_renderer():
            print(
                "xontrib-helix: no buffer control found in the prompt layout; selections will not be highlighted.",
                file=sys.stderr,
            )
        helix.selection_style = installation.selection_style()
        helix.secondary_cursor_style = installation.secondary_cursor_style()
        installation.helix = helix
        XSH.env["XONSH_PROMPT_CURSOR_SHAPE"] = helix.cursor_shapes()

    @events.on_pre_prompt
    def _on_pre_prompt(**_):
        # Per prompt, not per session: `editing_mode` is re-derived from
        # `$VI_MODE` on every `prompt()` call, so no state of ours may live on
        # the application object.
        if installation.helix is not None:
            installation.helix.reset_prompt()
            installation.helix.selection_style = installation.selection_style()
            installation.helix.secondary_cursor_style = installation.secondary_cursor_style()
            # `singleline` sets its own timeouts just before firing this event.
            installation.helix.apply_timeouts()

    installation._hooks = [
        (events.on_ptk_create, _on_ptk_create),
        (events.on_pre_prompt, _on_pre_prompt),
    ]
    XSH.env["PROMPT_FIELDS"]["helix_mode"] = ModeField(installation)
    XSH.env["PROMPT_FIELDS"]["helix_pending"] = PendingField(installation)
    _installation = installation
    return installation
