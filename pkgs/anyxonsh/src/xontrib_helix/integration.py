"""Wiring the Helix editor into prompt_toolkit, and then into xonsh.

The only module here that imports either. Everything it does falls into three
jobs:

1. Translate prompt_toolkit key presses into the canonical tokens `editor.feed`
   understands.
2. Keep `Editor.text`/`Editor.range` and the prompt_toolkit `Buffer` in sync.
3. Turn a `ShellRequest` into the thing only the shell can do.

Insert mode is deliberately *not* routed through the editor. Typing, backspace,
`c-w`, completion, auto-suggestion and xonsh's abbreviation expansion are all
prompt_toolkit and xonsh behaviour that already works; intercepting it would
mean reimplementing it worse. Only `<esc>` is bound there, and the editor picks
the text back up from the buffer on the way out.

The exception is `Editor.owns_input`: typing into more than one cursor, and
typing a regex for `s`. prompt_toolkit has no idea either state exists -- it
draws one cursor and it would treat the regex as text -- so while one of them is
on, every key comes through `_dispatch` and the buffer is written from the
editor rather than read from it.

A terminal has one cursor, and prompt_toolkit puts it at
`Buffer.cursor_position`, which is the primary. Every other cursor is *painted*
by `_HelixSelectionProcessor`, in reverse video, which is what a block cursor
looks like anyway.

Binding precedence, which this depends on: prompt_toolkit sorts candidate
bindings by how many `Keys.Any` wildcards they contain and takes the *last*
match, so a specific binding beats a wildcard one regardless of registration
order, and ties go to whoever registered last. Our registry is merged last, so
we win ties -- but a bare `Keys.Any` still loses to any default binding for a
named key. Hence the explicit list in `_bind_named` and `_ALT_KEYS`.
"""

from __future__ import annotations

import sys

from prompt_toolkit.cursor_shapes import CursorShape, CursorShapeConfig
from prompt_toolkit.document import Document
from prompt_toolkit.filters import Condition
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.keys import Keys
from prompt_toolkit.layout.controls import BufferControl
from prompt_toolkit.layout.processors import Processor, Transformation
from prompt_toolkit.layout.utils import explode_text_fragments

from .editor import Editor, Mode, ShellRequest
from .selection import Range, Selection
from .terminal import query_background, shifted

#: prompt_toolkit key -> canonical token. Anything not listed is either a
#: printable character (used as-is) or something we do not handle.
_NAMED = {
    Keys.Escape: "<esc>",
    Keys.ControlM: "<ret>",
    Keys.ControlJ: "<ret>",
    Keys.ControlI: "<tab>",
    Keys.BackTab: "<tab>",
    Keys.Backspace: "<backspace>",
    Keys.Delete: "<del>",
    Keys.Left: "<left>",
    Keys.Right: "<right>",
    Keys.Up: "<up>",
    Keys.Down: "<down>",
    Keys.Home: "<home>",
    Keys.End: "<end>",
    Keys.PageUp: "<pageup>",
    Keys.PageDown: "<pagedown>",
}

#: Named keys we bind explicitly in normal/select mode. Without these, the
#: default emacs bindings win -- they name the key exactly, and a `Keys.Any`
#: binding is sorted behind anything more specific.
_NAMED_BINDINGS = (
    Keys.Left,
    Keys.Right,
    Keys.Up,
    Keys.Down,
    Keys.Home,
    Keys.End,
    Keys.Backspace,
    Keys.Delete,
)

#: Alt combinations Helix gives a meaning of its own.
#:
#: Every one of these gives up "Escape, then that character typed within
#: `TIMEOUTLEN`" -- the two are the same bytes and only the pause tells them
#: apart. A person pressing Escape and then reaching for a key takes longer than
#: 50ms, so this costs nothing they will notice; what it does cost is Escape
#: followed instantly by one of these, which is a paste or a macro rather than a
#: keyboard.
_ALT_KEYS = frozenset(";:.dc`J" + ",sCK-_()")

#: Every printable character, each bound as `escape <char>`.
#:
#: A terminal sends Alt-x as ESC followed by x, so prompt_toolkit cannot tell
#: Alt-b from "Escape, then b" except by waiting. The emacs defaults bind
#: `escape b` and `escape f` by name, which beats a wildcard binding -- so
#: without claiming these, leaving insert mode and immediately pressing `b`
#: would run `backward-word` instead of Helix's `b`. Since Escape into a command
#: is *the* most common Helix keystroke, the whole prefix is claimed and the
#: emacs Alt bindings are given up. Named keys are left alone, so Alt-Backspace
#: still deletes a word.
_ESCAPE_FOLLOWERS = tuple(chr(c) for c in range(0x20, 0x7F))

#: How long prompt_toolkit waits on an ambiguous prefix, replacing the 1.0s
#: xonsh asks for.
#:
#: Claiming `escape <char>` for the Alt keys makes a bare Escape a prefix of a
#: longer binding, so the key processor cannot dispatch it until either another
#: key arrives or this expires. At a whole second that reads as nothing having
#: happened -- press Escape, watch the mode indicator sit on INS until you
#: press something else. Going the other way never had the problem: `i` is not
#: a prefix of anything and runs the moment it is read.
#:
#: Safe to shorten because a real Alt-x arrives as two key presses in a single
#: read and matches without ever reaching the timeout. Only a human pressing
#: Escape and then pausing gets here. Matches the 0.05 xonsh uses for
#: `ttimeoutlen`, the same tradeoff one layer down.
TIMEOUTLEN = 0.05

#: xonsh's own knob for the above. Set it and we keep out of the way.
TIMEOUTLEN_VAR = "XONSH_PTK_TIMEOUTLEN"

#: Painted over the selection when the terminal will not say what colour it is
#: (see `terminal.query_background`). Assumes a dark terminal, because that is
#: the common case and because guessing wrong is what
#: `$XONTRIB_HELIX_SELECTION_STYLE` is for.
FALLBACK_SELECTION_STYLE = "bg:#3a3a4a"

#: Overrides the selection style outright. Any prompt_toolkit style string --
#: `bg:#402030`, `underline`, or `class:selected` to go back to prompt_toolkit's
#: reverse video. Re-read once per prompt, so it can be tuned by eye.
SELECTION_STYLE_VAR = "XONTRIB_HELIX_SELECTION_STYLE"

#: How every cursor but the primary is drawn. Reverse video, because that is
#: what a terminal's own block cursor looks like and the two should not be
#: distinguishable -- there is nothing special about whichever one prompt_toolkit
#: happens to be able to draw. It is also exactly why the *selection* is painted
#: with a lifted background instead; see `_HelixSelectionProcessor`.
SECONDARY_CURSOR_STYLE = "reverse"

#: Overrides the above. Same values as `$XONTRIB_HELIX_SELECTION_STYLE`.
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


class HelixMode:
    """Helix editing installed on one prompt_toolkit session."""

    def __init__(self, session, *, bindings=None, initial_mode: Mode = Mode.INSERT):
        self.session = session
        self.initial_mode = initial_mode
        self.editor = Editor(mode=initial_mode)
        #: Every binding is gated on this. prompt_toolkit has no way to remove a
        #: binding once merged into a registry, so `xontrib unload helix` turns
        #: them off here instead -- otherwise editing would carry on working
        #: while `on_pre_prompt` no longer fired `reset()`, which is the
        #: state-leaking-across-prompts bug all over again.
        self.enabled = True
        #: Mirrors xonsh's `should_confirm_completion`. Overridden in tests; the
        #: default answers True where there is no xonsh to ask.
        self.confirm_completion = _completions_confirm
        #: The style string painted over the selection. Set by `setup` from the
        #: terminal's own background colour; see `FALLBACK_SELECTION_STYLE`.
        self.selection_style = FALLBACK_SELECTION_STYLE
        #: The style string painted over every cursor but the primary.
        self.secondary_cursor_style = SECONDARY_CURSOR_STYLE
        #: Bindings go straight into the caller's registry when it supplies one
        #: -- under xonsh that is the registry it passes to `prompt()` last,
        #: which is what puts us at the end of the merge order.
        self.key_bindings = bindings if bindings is not None else KeyBindings()
        #: Live history-search state, or None. See `_open_histsearch`.
        self.histsearch: dict | None = None
        self.apply_timeouts()
        self._wire_clipboard()
        self._bind()

    def apply_timeouts(self) -> None:
        """Put our key-sequence timeout back on the application.

        Every prompt, not once. xonsh's `singleline` assigns
        `app.timeoutlen` from `$XONSH_PTK_TIMEOUTLEN` -- default 1.0 -- at the
        top of each prompt, so anything set when the session was created is
        gone before the first key is read. Same hazard the `on_pre_prompt` hook
        in `setup` is there for: no state of ours survives on that object.

        Does nothing if `$XONSH_PTK_TIMEOUTLEN` is set. Someone who has reached
        for xonsh's own knob has said what they want.
        """
        if _env_get(TIMEOUTLEN_VAR) is not None:
            return
        self.session.app.timeoutlen = TIMEOUTLEN

    # ------------------------------------------------------------- lifecycle --

    def reset(self) -> None:
        """Start a fresh prompt in the mode this session starts in.

        Called per prompt rather than per session: `editing_mode` is re-derived
        from `$VI_MODE` on every `PromptSession.prompt()` call, so nothing about
        our state can live on the application.
        """
        editor = self.editor
        editor.mode = self.initial_mode
        editor.text = ""
        editor.selection = Selection.point(0)
        # Undo history, a dangling `g`, a half-typed count: all of it belongs to
        # the line just submitted, and all of it would otherwise be waiting at
        # the next prompt.
        editor.reset_transient()
        # An open history search cannot survive the line it opened on.
        self.histsearch = None

    @property
    def mode(self) -> Mode:
        return self.editor.mode

    def cursor_shape_config(self) -> CursorShapeConfig:
        return _HelixCursorShape(self)

    # ------------------------------------------------------------------ sync --

    @property
    def _buffer(self):
        return self.session.default_buffer

    # ---------------------------------------------------------- histsearch --

    def histsearch_active(self) -> bool:
        """Is `/` history search open right now?"""
        return self.histsearch is not None

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
            "typing": self.session.complete_while_typing,
        }
        buf.text = ""
        buf.cursor_position = 0
        buf.completer = HistorySearchCompleter()
        buf.complete_while_typing = True
        self.session.complete_while_typing = True
        self.editor.mode = Mode.INSERT
        self._adopt_buffer()
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
        self.session.complete_while_typing = st["typing"]

        chosen = None
        if accept:
            state = buf.complete_state
            if state is not None and state.current_completion is not None:
                chosen = state.current_completion.completion.text

        if accept and (chosen is not None or buf.text):
            # Keep what the box produced: the highlighted alternative, or the
            # bare query when nothing matched but something was typed. Stays in
            # insert mode -- the next Enter runs it, exactly like any line.
            final = chosen if chosen is not None else buf.text
            buf.cancel_completion()
            buf.text = final
            buf.cursor_position = len(final)
            self._adopt_buffer()
        else:
            # Escape, or accept on an empty query: the line you came with.
            buf.cancel_completion()
            buf.text = st["text"]
            buf.cursor_position = min(st["cursor"], len(buf.text))
            self._adopt_buffer()
            self.editor.mode = Mode.NORMAL

    def _sync_in(self) -> None:
        """Adopt whatever the buffer says before interpreting a key.

        Necessary because insert mode is handled by prompt_toolkit, and because
        history recall and completion replace the text behind our back.
        """
        buf = self._buffer
        editor = self.editor
        if editor.owns_input:
            # Nothing to adopt: while the editor owns the keys, the buffer is
            # written from it and never the other way round. Reading the
            # buffer's single cursor position back here would collapse every
            # cursor but the primary onto it.
            return
        if editor.mode is Mode.INSERT:
            # Move the anchor through the edit rather than over it: typing at
            # the anchor must carry it along, or leaving insert mode would find
            # the whole line selected instead of a cursor on the last keystroke.
            editor.adopt_text(buf.text)
            editor.range = Range(editor.range.anchor, buf.cursor_position)
        else:
            # Outside insert mode a text change means something replaced the
            # buffer wholesale -- history recall, a completion -- and there is
            # no edit to map a selection through.
            if buf.text != editor.text:
                editor.range = Range.point(buf.cursor_position)
            editor.text = buf.text
        editor.ensure_invariants()

    def _sync_out(self) -> None:
        buf = self._buffer
        editor = self.editor
        if buf.text != editor.text:
            # One assignment rather than text-then-cursor: an intermediate state
            # where the cursor is past the end of the new text is briefly
            # visible to `on_text_changed` handlers otherwise.
            buf.document = Document(editor.text, editor.caret)
        elif buf.cursor_position != editor.caret:
            buf.cursor_position = editor.caret

    def selection_spans(self) -> list[tuple[int, int]]:
        """The spans to highlight. Empty for bare cursors.

        Deliberately *not* prompt_toolkit's `Buffer.selection_state`, for three
        reasons. Its emacs-mode selection excludes the character under the
        cursor, so a Helix range could only be rendered by putting the cursor
        one past where Helix puts it -- and then `d` would delete something
        other than what the highlight shows. A non-null `selection_state`
        switches off the `emacs_insert_mode` filter, which xonsh gates its Enter
        and completion bindings on, so a live selection would quietly stop
        Enter from submitting a multi-line command. And there is only one of it,
        where Helix has as many as you have made.

        A one-wide range is left out: the block cursor already shows it, and
        painting a background under it only makes the cursor harder to find.

        `_HelixSelectionProcessor` reads this instead.
        """
        editor = self.editor
        if editor.mode is Mode.INSERT:
            return []
        return [(rng.start, rng.end) for rng in editor.selection if len(rng) > 1]

    def secondary_cursors(self) -> list[int]:
        """Where to paint a cursor because the terminal cannot put one there.

        Everything except the primary, which is the one prompt_toolkit draws at
        `Buffer.cursor_position`. In insert mode a caret sitting past the last
        character of its line has nothing to paint over and is invisible; the
        text appearing there as you type is what says it exists.
        """
        editor = self.editor
        selection = editor.selection
        if not selection.multi:
            return []
        return [
            editor.caret_of(rng)
            for index, rng in enumerate(selection)
            if index != selection.primary_index
        ]

    def install_renderer(self) -> bool:
        """Add the selection highlighter to this session's buffer control.

        The control is a local in `PromptSession._create_layout`, so it is found
        by walking the layout. Returns False if it could not be found, in which
        case editing still works and only the highlight is missing.

        Any processor an earlier `HelixMode` left on this control is *replaced*,
        not skipped. Two processors would apply `class:selected` twice; keeping
        the old one would be worse still, because it paints from a `HelixMode`
        that no longer receives keys -- the range would never leave `(0, 0)` and
        nothing would ever highlight. See `setup`, which is what stops a second
        `HelixMode` from being built in the first place.
        """
        for control in self.session.app.layout.find_all_controls():
            if isinstance(control, BufferControl) and control.buffer is self._buffer:
                processors = control.input_processors
                if processors is None:
                    processors = control.input_processors = []
                mine = _HelixSelectionProcessor(self)
                for i, existing in enumerate(processors):
                    if isinstance(existing, _HelixSelectionProcessor):
                        processors[i] = mine
                        break
                else:
                    processors.append(mine)
                return True
        return False

    def _wire_clipboard(self) -> None:
        def get() -> str:
            data = self.session.app.clipboard.get_data()
            return data.text if data is not None else ""

        def put(text: str) -> None:
            from prompt_toolkit.clipboard import ClipboardData

            self.session.app.clipboard.set_data(ClipboardData(text))

        self.editor.clipboard_get = get
        self.editor.clipboard_set = put

    # -------------------------------------------------------------- bindings --

    def _ours(self) -> bool:
        """Should this keystroke go to the editor rather than to the buffer?"""
        return self.enabled and (
            self.editor.mode is not Mode.INSERT or self.editor.owns_input
        )

    def _bind(self) -> None:
        add = self.key_bindings.add
        enabled = Condition(lambda: self.enabled)
        ours = Condition(self._ours)
        reading = Condition(lambda: self.enabled and self.editor.reading)

        @add(Keys.Any, filter=ours)
        def _any(event):
            self._dispatch(event, event.key_sequence[0].data or "")

        # Every printable character again, by name. `Keys.Any` loses to any
        # binding that names the key, and there are such bindings live in
        # insert mode -- xonsh's `abbrevs` claims space, for one. In normal mode
        # `Keys.Any` already covered these and this changes nothing; in
        # multi-cursor insert mode it is what stops a space from expanding an
        # abbreviation instead of being typed into all the cursors.
        for char in _ESCAPE_FOLLOWERS:

            @add(char, filter=ours)
            def _printable(event, _char=char):
                self._dispatch(event, _char)

        for key in _NAMED_BINDINGS:

            @add(key, filter=ours)
            def _named(event):
                self._dispatch(event, _NAMED.get(event.key_sequence[0].key, ""))

        # Ctrl-R opens history search -- deliberately NOT `/`, which keeps its
        # Helix meaning: search inside the current line, selections and all.
        # The line becomes a filter over this shell's history and
        # prompt_toolkit's completion menu is the flowing alternatives box
        # under it. Bound in both modes: reflexes reach for Ctrl-R mid-typing.
        # Ours replaces prompt_toolkit's own reverse-search outright -- same
        # merge-order logic as every binding here.
        searching = Condition(lambda: self.enabled and self.histsearch_active())

        @add(Keys.ControlR, filter=enabled)
        def _histsearch_open(event):
            if not self.histsearch_active():
                self._open_histsearch(event)

        # While search is open, Enter accepts: the highlighted alternative
        # replaces the line, or the bare query when nothing matched. The line
        # stays editable in insert mode; the next Enter runs it.
        for key in (Keys.ControlM, Keys.ControlJ):

            @add(key, filter=searching)
            def _histsearch_accept(event):
                self._close_histsearch(event, accept=True)

        # Enter, but only while a regex is being read. Everywhere else it stays
        # xonsh's -- see the note at the end of this method -- but here it has
        # to mean "that is the pattern" rather than "run this command", and
        # nobody else knows the state exists.
        for key in (Keys.ControlM, Keys.ControlJ):

            @add(key, filter=reading)
            def _reading_enter(event):
                self._dispatch(event, "<ret>")

        # Escape is bound in *both* modes -- it is how insert mode is left.
        @add(Keys.Escape, filter=enabled)
        def _escape(event):
            if self.histsearch_active():
                self._close_histsearch(event, accept=False)
                return
            if self._cancel_completion(event):
                return
            self._dispatch(event, "<esc>")

        # Kitty keyboard protocol, when the terminal answered at startup: the
        # disambiguate flag makes modified Enter arrive as a CSI-u sequence
        # instead of being indistinguishable from plain Enter. prompt_toolkit
        # cannot parse those, so they surface here as an escape-led key run --
        # which we bind by hand and turn into what they mean. Shift+Enter and
        # friends are real multiline input, no backslash continuations.
        if _env_get("ANYXONSH_KEYBOARD") == "kitty":
            inserting = Condition(
                lambda: self.enabled
                and not self.editor.owns_input
                and self.editor.mode is Mode.INSERT
            )
            for mod in ("2", "3", "5"):  # shift, alt, ctrl

                @add(Keys.Escape, "[", "1", "3", ";", mod, "u", filter=inserting)
                def _csi_u_enter(event):
                    event.current_buffer.insert_text("\n")

                # And in normal mode they drop you on an open line below.
                @add(Keys.Escape, "[", "1", "3", ";", mod, "u",
                     filter=enabled & Condition(lambda: self.editor.mode is Mode.NORMAL))
                def _csi_u_enter_normal(event):
                    buf = event.current_buffer
                    buf.insert_text("\n")
                    self._adopt_buffer()
                    self.editor.mode = Mode.INSERT

        for char in _ESCAPE_FOLLOWERS:

            @add(Keys.Escape, char, filter=enabled)
            def _escape_then(event, _char=char):
                if self.editor.mode is not Mode.INSERT and _char in _ALT_KEYS:
                    self._dispatch(event, f"<A-{_char}>")
                elif self._cancel_completion(event):
                    # That Escape spent itself closing the menu, so the mode is
                    # unchanged and the character that followed is ordinary
                    # input for whatever mode we were already in.
                    if self.editor.mode is Mode.INSERT:
                        event.current_buffer.insert_text(_char)
                    else:
                        self._dispatch(event, _char)
                else:
                    # Escape first, so the character is interpreted in whatever
                    # mode Escape leaves us in. Typing, Escape, `b` moves back a
                    # word, which is the whole point of claiming these.
                    self._dispatch(event, "<esc>")
                    self._dispatch(event, _char)

        # Enter and Tab are deliberately unbound. xonsh's own handlers for them
        # -- the multi-line continuation parser, the completion menu -- are
        # still live in normal mode, because keeping `selection_state` unset
        # leaves `emacs_insert_mode` true. Binding them here would shadow those
        # and mean reimplementing xonsh's parser.

    def _cancel_completion(self, event) -> bool:
        """Let Escape dismiss an open completion menu, as it does everywhere else.

        xonsh binds Escape to `esc_cancel_completion` under
        `should_confirm_completion`; our binding is registered later and is just
        as specific, so it would win and switch to normal mode with the menu
        still up. Restore the expected precedence by hand: menu first, mode
        change on the *next* Escape.

        Mirroring xonsh's whole condition, `$COMPLETIONS_CONFIRM` included, not
        just the open menu. With `$UPDATE_COMPLETIONS_ON_KEYPRESS` a completion
        state is live most of the time you are typing, so checking the menu
        alone would make leaving insert mode take two Escapes for anyone who has
        turned confirmation off -- and turning it off is precisely how you say
        you do not want Escape spent on completions.
        """
        buf = event.current_buffer
        if buf.complete_state is None or not self.confirm_completion():
            return False
        buf.cancel_completion()
        return True

    def _dispatch(self, event, token: str) -> None:
        if not token:
            return
        self._sync_in()
        request = self.editor.feed(token)
        self._sync_out()
        if request is not None:
            self._handle(request, event)

    def _handle(self, request: ShellRequest, event) -> None:
        buf = event.current_buffer
        if request is ShellRequest.ACCEPT:
            _carriage_return(buf, event.app)
        elif request is ShellRequest.ABORT:
            buf.reset()
        elif request is ShellRequest.COMPLETE:
            buf.start_completion()
        elif request is ShellRequest.HISTORY_PREV:
            buf.history_backward(count=event.arg)
            self._adopt_buffer()
        elif request is ShellRequest.HISTORY_NEXT:
            buf.history_forward(count=event.arg)
            self._adopt_buffer()

    def _adopt_buffer(self) -> None:
        """Re-read the buffer after something else replaced it wholesale."""
        buf = self._buffer
        self.editor.text = buf.text
        self.editor.range = Range.point(buf.cursor_position)
        self.editor.ensure_invariants()
        self._sync_out()


class _HelixSelectionProcessor(Processor):
    """Paint the Helix selection, and every cursor the terminal cannot draw.

    A near-copy of prompt_toolkit's `HighlightSelectionProcessor`, differing in
    where it gets the ranges from -- see `HelixMode.selection_spans` -- and in
    painting an explicit style rather than `class:selected`. That class resolves
    to `reverse`, which is what a block cursor already looks like, so cursor and
    selection were indistinguishable; a slightly lifted background separates
    them without drowning out the cursor sitting inside the selection.

    Secondary cursors are painted in that same reverse video afterwards, so
    where one sits inside a selection it comes out looking exactly like the
    primary sitting inside its own.
    """

    def __init__(self, helix: HelixMode):
        self.helix = helix

    def apply_transformation(self, transformation_input) -> Transformation:
        (
            _control,
            document,
            lineno,
            source_to_display,
            fragments,
            *_,
        ) = transformation_input.unpack()

        spans = self.helix.selection_spans()
        cursors = self.helix.secondary_cursors()
        if not spans and not cursors:
            return Transformation(fragments)

        row_start = document.translate_row_col_to_index(lineno, 0)
        row_end = row_start + len(document.lines[lineno])
        # Exploded lazily: a selection on another row of a multi-line command
        # must not pay for splitting this row's fragments up.
        exploded: list | None = None

        def paint(begin: int, end: int, style: str) -> None:
            nonlocal exploded
            begin, end = max(row_start, begin), min(row_end, end)
            if begin >= end:
                return
            if exploded is None:
                exploded = explode_text_fragments(fragments)
            for i in range(
                source_to_display(begin - row_start),
                source_to_display(end - row_start),
            ):
                if i < len(exploded):
                    existing, text, *rest = exploded[i]
                    exploded[i] = (existing + style, text, *rest)

        selection = f" {self.helix.selection_style} "
        for start, end in spans:
            paint(start, end, selection)

        cursor = f" {self.helix.secondary_cursor_style} "
        for position in cursors:
            paint(position, position + 1, cursor)

        return Transformation(fragments if exploded is None else exploded)


class _HelixCursorShape(CursorShapeConfig):
    """Block in normal mode, bar in insert, underline in select."""

    _SHAPES = {
        Mode.NORMAL: CursorShape.BLOCK,
        Mode.INSERT: CursorShape.BEAM,
        Mode.SELECT: CursorShape.UNDERLINE,
    }

    def __init__(self, helix: HelixMode):
        self.helix = helix

    def get_cursor_shape(self, application) -> CursorShape:
        return self._SHAPES[self.helix.mode]


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
        #: to answer. Asked once per shell -- the answer cannot change without
        #: the user reconfiguring the terminal under a running session.
        self.background: tuple[int, int, int] | None = None

    @property
    def mode_label(self) -> str:
        return self.helix.mode.label if self.helix is not None else ""

    @property
    def pending_label(self) -> str:
        """The half-typed command, with a leading space, or nothing at all.

        The space belongs to the value rather than to the prompt template
        because a prompt field cannot ask to be skipped when it is empty --
        xonsh's `{field: {}}` form only hides fields whose value is `None`, and
        this is an object precisely so that it is read at render time rather
        than cached once per prompt. See `ModeField`.
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
        half-typed commands would start leaking between prompts again -- worse
        than either loaded or unloaded.
        """
        for event, handler in self._hooks:
            event.discard(handler)
        self._hooks.clear()
        if self.helix is not None:
            self.helix.enabled = False
            self.helix = None


class _LiveField:
    """A prompt field whose value is read when the prompt is *drawn*.

    A plain `lambda` looks right and is stuck on whatever was true when the line
    began. `PromptFields.pick` calls a field once and caches the string it
    returned; that cache is cleared once per prompt
    (`ptk_shell/__init__.py`), not once per keystroke. `$UPDATE_PROMPT_ON_KEYPRESS`
    re-renders on every key, but re-rendering re-*formats* the cached value --
    it never re-picks it. So a mode indicator would read INS for the whole line
    while the cursor shape, which is written directly, said otherwise.

    Caching an object instead of a string sidesteps the whole problem: `pick`
    stores this, and `_format_value` calls `format()` on it at each render, so
    the read happens there. That keeps the fix at the one place the field is
    registered, rather than at every place the state can change -- a keybinding
    added later cannot forget to invalidate something.

    Not callable, deliberately: `pick` calls anything callable and caches the
    result, which is the behaviour being avoided.
    """

    #: Attribute of `Installation` to read at render time.
    source = ""

    def __init__(self, installation: "Installation"):
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
    """The `{helix_mode}` prompt field: `NOR`, `INS` or `SEL`.

    Buys nothing under the readline shell, where nothing re-renders mid-line
    and the prompt is drawn once either way. That shell has no Helix editing to
    indicate: `on_ptk_create` never fires, so the label is empty.
    """

    source = "mode_label"


class PendingField(_LiveField):
    """The `{helix_pending}` prompt field: the command being typed.

    A count and a menu prefix (`2m`, `g`) while one is half-entered, and the
    regex while `s`, `S`, `K` or `Alt-K` is reading one -- which is the only
    place it is load-bearing rather than a nicety. Typing a regex you cannot
    see is not something anyone should be asked to do, and this is the one
    surface that re-renders per keystroke without opening a second buffer.

    Empty unless there is something to say, and it carries its own leading
    space -- see `Installation.pending_label`.
    """

    source = "pending_label"


#: The one live installation in this process, or `None`. See `setup`.
_installation: Installation | None = None


def drawn_by_prompt_toolkit() -> bool:
    """Is this xonsh drawing its prompt with prompt_toolkit, or going to be?

    Two answers, because there are two moments this gets asked from and only
    one of them has a shell to ask.

    Where there is one, `prompter` is the tell: `PromptToolkitShell.__init__`
    builds one, and neither the readline shell nor the dumb shell -- which is
    the readline shell, whatever `$SHELL_TYPE` says -- has anything of the sort.

    Where there is not, which is every rc file, xonsh sources those *before*
    building the shell -- which is the whole reason `setup` waits on
    `on_ptk_create` rather than reaching for the session directly. So ask xonsh
    the question it is about to answer itself: `choose_shell_type` is the same
    resolution it will run in a moment, including `best`, including
    `$TERM=dumb` beating `$SHELL_TYPE`, and including falling back to readline
    when prompt_toolkit cannot be imported.
    """
    from xonsh.built_ins import XSH

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


def setup(*, initial_mode: Mode = Mode.INSERT) -> Installation:
    """Install Helix editing into the running xonsh shell.

    Idempotent, and that matters: `xontrib load helix` twice -- or a `xontrib
    reload`, or an rc file that loads it alongside xonsh's entry-point
    autoloader -- would otherwise register a second `on_ptk_create` handler and
    build a second `HelixMode` on the same session. Both sets of bindings land
    in the same registry, the later one wins every tie, and the earlier one is
    left owning the selection highlight while never seeing another keystroke:
    editing works and nothing ever highlights.

    Registers `{helix_mode}` and `{helix_pending}` prompt fields but does not
    put either in any prompt: a textual indicator forces
    `$UPDATE_PROMPT_ON_KEYPRESS`, which re-renders the prompt on every
    keystroke. Spending that is the caller's decision -- see the editing-mode
    block in rc.xsh, which does.

    Refuses without prompt_toolkit, and says so. Helix mode *is* a set of
    prompt_toolkit key bindings and a prompt_toolkit renderer; there is nothing
    of it that survives without one. This used to load and then quietly do
    nothing -- `on_ptk_create` never fires, `Installation.helix` stays `None`
    -- which is the same outcome reached by silence, and silence is how you end
    up typing at a shell wondering why `w` does not move by a word.

    Said once rather than raised: this is reached from an rc file, and a
    traceback on every shell start is a worse answer than a sentence.
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
    # Before prompt_toolkit exists, let alone owns the terminal: this reads the
    # tty directly, and the window where nothing else is listening is exactly
    # the one an rc file runs in.
    #
    # Interactive runs only. `anyxonsh -c '...'` started from a terminal has a
    # tty on both ends, so `query_background` would happily switch it to cbreak,
    # write an escape sequence into the command's own output and wait out the
    # timeout -- all for a shell that never draws a prompt. `$XONSH_INTERACTIVE`
    # is set from the command line before the rc files run, so it is already
    # right here; the same guard is what `xontrib/term_integration.py` uses.
    if _env_get("XONSH_INTERACTIVE", False):
        installation.background = query_background()

    @events.on_ptk_create
    def _on_ptk_create(prompter, history, completer, bindings, **_):
        # `bindings` is xonsh's own registry, and xonsh hands it to `prompt()`
        # after prompt_toolkit's defaults -- so binding into it directly is what
        # puts these at the end of the merge order, where ties are won.
        helix = HelixMode(prompter, bindings=bindings, initial_mode=initial_mode)
        if not helix.install_renderer():
            # Editing still works; only the highlight is missing. Say so rather
            # than letting the most visible part of Helix mode fail in silence
            # -- the layout walk is the one piece here that depends on how
            # prompt_toolkit builds a session, which is not ours to control.
            print(
                "xontrib-helix: no buffer control found in the prompt layout; "
                "selections will not be highlighted.",
                file=sys.stderr,
            )
        helix.selection_style = installation.selection_style()
        helix.secondary_cursor_style = installation.secondary_cursor_style()
        installation.helix = helix
        XSH.env["XONSH_PROMPT_CURSOR_SHAPE"] = helix.cursor_shape_config()

    @events.on_pre_prompt
    def _on_pre_prompt(**_):
        # Per prompt, not per session: `editing_mode` is re-derived from
        # `$VI_MODE` on every `prompt()` call, so no state of ours may live on
        # the application object.
        if installation.helix is not None:
            installation.helix.reset()
            # Re-read here rather than per render: one env lookup a prompt is
            # free, and it means `$XONTRIB_HELIX_SELECTION_STYLE` can be tuned
            # by eye without restarting the shell.
            installation.helix.selection_style = installation.selection_style()
            installation.helix.secondary_cursor_style = (
                installation.secondary_cursor_style()
            )
            # `singleline` sets its own timeouts a couple of lines above firing
            # this event, so ours has to go back on afterwards.
            installation.helix.apply_timeouts()

    installation._hooks = [
        (events.on_ptk_create, _on_ptk_create),
        (events.on_pre_prompt, _on_pre_prompt),
    ]
    # Objects rather than callables, so they survive xonsh's field cache and
    # are read at render time -- see `_LiveField`.
    XSH.env["PROMPT_FIELDS"]["helix_mode"] = ModeField(installation)
    XSH.env["PROMPT_FIELDS"]["helix_pending"] = PendingField(installation)
    _installation = installation
    return installation
