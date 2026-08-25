"""The modal editor itself: document state plus the key dispatch state machine.

Deliberately knows nothing about prompt_toolkit. Everything it cannot do on its
own -- accept the line, walk shell history, reach the system clipboard -- it
reports back as a `ShellRequest` for the integration layer to carry out. That
keeps the entire keymap testable as `text + keys -> text` with no terminal, no
event loop and no xonsh, which is what `tests/test_helix_keymap.py` exercises.

Multiple cursors are the reason this is a state machine over a `Selection`
rather than over a `Range`. Every command maps over all of them: `s` splits one
selection into every regex match inside it, and the `c` that follows deletes at
all of them and puts a caret at each. The two primitives that make that work are
`_splice`, which applies a batch of edits and carries every range through the
change, and `_edit_each`, which builds one edit per range and hands back a
selection over what it wrote.

Divergences from Helix proper, all deliberate:

* No `/`, `?`, `n`, `N`. Those open a prompt inside a prompt, which is a
  different piece of machinery again. `s`, `S`, `K` and `Alt-K` do read a regex,
  but they read it *here* -- see `_Reading` -- and show it through the
  `{helix_pending}` prompt field rather than by opening a second buffer.
* No `&` (align selections in columns). It aligns code by visual column, and a
  shell command line has no columns to align.
* Movement is by code point rather than grapheme cluster, and `C` counts
  columns in characters rather than in display cells. Both only show up on
  wide and combining characters.
* A shell buffer has no trailing newline, so the cursor is allowed to rest one
  position past the last character. Helix instead keeps a newline there for the
  cursor to sit on. The visible effect is the same; the range is zero-width
  where Helix's would be one wide.
* During insert mode `range.head` is the caret itself, where Helix keeps it one
  past the block cursor. The two agree again on leaving insert mode: the
  grapheme between them is exactly the one Helix's `restore_cursor` subtracts.
  See `exit_insert`.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum

from . import movement as mv
from .keys import alt_key, is_alt, is_printable
from .selection import (
    Direction,
    Range,
    Selection,
    char_to_line,
    line_bounds,
    line_count,
    line_to_char,
    next_grapheme,
)

INDENT = "    "

#: `(start, end, replacement)` against the text as it is *before* any of the
#: batch is applied. What `_splice` takes.
Edit = tuple[int, int, str]


class Mode(Enum):
    NORMAL = "normal"
    INSERT = "insert"
    SELECT = "select"

    @property
    def label(self) -> str:
        return {"normal": "NOR", "insert": "INS", "select": "SEL"}[self.value]


class ShellRequest(Enum):
    """Something only the shell can do. Returned from `Editor.feed`."""

    ACCEPT = "accept"
    ABORT = "abort"
    HISTORY_PREV = "history-prev"
    HISTORY_NEXT = "history-next"
    COMPLETE = "complete"


@dataclass
class _Find:
    char: str
    direction: Direction
    inclusive: bool


@dataclass
class _Reading:
    """A regex being typed for `s`, `S`, `K` or `Alt-K`.

    `base` is the selection the command was invoked on, kept so that every
    keystroke re-derives the result from it rather than from the last preview.
    Without that, deleting a character could not widen the selection back out
    again -- each keystroke would narrow whatever the previous one left.
    """

    kind: str
    base: Selection
    pattern: str = ""

    #: What the `{helix_pending}` prompt field shows while this is being typed.
    LABELS = {"s": "select:", "S": "split:", "K": "keep:", "K!": "remove:"}

    @property
    def label(self) -> str:
        return f"{self.LABELS.get(self.kind, self.kind)}{self.pattern}"


@dataclass
class Editor:
    text: str = ""
    selection: Selection = Selection.point(0)
    mode: Mode = Mode.NORMAL

    #: Yank registers, each holding one string *per cursor*. A yank with three
    #: cursors keeps three fragments, and pasting them back with three cursors
    #: puts each one where it came from -- which is most of the point of having
    #: cursors at all. Fewer values than cursors and the last one repeats.
    #: `"` is the default register; `_` is the black hole.
    registers: dict[str, list[str]] = field(default_factory=dict)
    #: Set by `"x`, consumed by the next yank/delete/paste.
    pending_register: str | None = None

    #: Reached through callbacks so the pure tests stay pure: the ptk layer
    #: swaps in prompt_toolkit's clipboard, which under xonsh is the system one.
    clipboard_get: Callable[[], str] = lambda: ""
    clipboard_set: Callable[[str], None] = lambda _text: None

    _count: str = ""
    _pending: tuple[str, ...] = ()
    _reading: _Reading | None = None
    _last_find: _Find | None = None
    _preferred_column: int | None = None
    _undo: list[tuple[str, Selection]] = field(default_factory=list)
    _redo: list[tuple[str, Selection]] = field(default_factory=list)

    # ---------------------------------------------------------------- state --

    @property
    def range(self) -> Range:
        """The primary range: where the terminal's own cursor is drawn.

        Assigning collapses to a single cursor, which is what every caller that
        assigns wants -- a fresh prompt, a recalled history entry, a completion
        that replaced the buffer. Commands build a whole `Selection` instead.
        """
        return self.selection.primary

    @range.setter
    def range(self, rng: Range) -> None:
        self.selection = Selection.single(rng.anchor, rng.head)

    @property
    def count(self) -> int:
        return int(self._count) if self._count else 1

    @property
    def caret(self) -> int:
        """Where a typed character lands, and where the terminal cursor goes."""
        return self.caret_of(self.range)

    def caret_of(self, rng: Range) -> int:
        if self.mode is Mode.INSERT:
            return min(rng.head, len(self.text))
        return rng.cursor(self.text)

    @property
    def extend(self) -> bool:
        return self.mode is Mode.SELECT

    @property
    def reading(self) -> bool:
        """Is a regex being typed for `s`, `S`, `K` or `Alt-K`?"""
        return self._reading is not None

    @property
    def owns_input(self) -> bool:
        """Must every key come through `feed`, even in insert mode?

        Insert mode is normally prompt_toolkit's: it already does completion,
        auto-suggestion and abbreviation expansion, and intercepting that would
        mean reimplementing it worse. Two states are the exception, because
        prompt_toolkit has no idea they exist -- typing into more than one
        cursor, and typing a regex for `s`.
        """
        return self._reading is not None or (
            self.mode is Mode.INSERT and self.selection.multi
        )

    @property
    def pending(self) -> str:
        """The half-typed command, for a status indicator. Empty when idle."""
        if self._reading is not None:
            return self._reading.label
        return self._count + "".join(self._pending)

    def clamp(self) -> None:
        self.selection = self.selection.clamped(self.text)

    def ensure_invariants(self) -> None:
        """Helix's `Selection::ensure_invariants`, applied after every command.

        Motions return a bare point when they are not extending -- `put_cursor`
        with `extend = false` is literally `Range::point`. What makes the result
        a one-wide block cursor is `Document::set_selection` widening it
        afterwards, so every command path has to do the same or `l` leaves you
        with an invisible zero-width selection.

        The widening is skipped in insert mode, where a zero-width range is the
        correct representation of a caret between two characters. The sorting
        and merging that `Selection` does is not: two carets that have been
        typed into the same position are one caret, and leaving both would
        double every subsequent keystroke.
        """
        if self.mode is Mode.INSERT:
            self.clamp()
        else:
            self.selection = self.selection.ensure_invariants(self.text)

    # ------------------------------------------------------------ registers --

    def _register_read(self, name: str | None) -> list[str]:
        name = name or '"'
        if name == "_":
            return []
        if name in "+*":
            value = self.clipboard_get()
            return [value] if value else []
        return self.registers.get(name, [])

    def _register_write(self, name: str | None, values: list[str]) -> None:
        name = name or '"'
        if name == "_":
            return
        if name in "+*":
            # One string is all a system clipboard can hold, so the fragments
            # are joined the way a `y` over whole lines would have left them.
            self.clipboard_set("\n".join(values))
            return
        self.registers[name] = values

    # ----------------------------------------------------------------- undo --

    def _snapshot(self) -> None:
        self._undo.append((self.text, self.selection))
        self._redo.clear()

    def reset_transient(self) -> None:
        """Drop everything scoped to a single line, for the next prompt.

        Undo history, a half-typed command and a pending count all belong to
        the line that is being abandoned: without this, `u` at a fresh prompt
        would restore the *previous* command's text, and a `g` left dangling by
        pressing Enter would swallow the next prompt's first keystroke.

        Registers and the last `f`/`t` target deliberately survive -- yanking on
        one line and pasting on the next is the point of a register, and Helix
        keeps both across buffers too.

        The current state becomes the new undo baseline rather than leaving the
        stack empty. Insert mode belongs to prompt_toolkit, so nothing typed at
        a fresh prompt is snapshotted by `enter_insert`; without a baseline `u`
        would be a no-op until the first normal-mode edit, where Helix would
        have cleared the line.
        """
        self._redo.clear()
        self._undo.clear()
        self._undo.append((self.text, self.selection))
        self._pending = ()
        self._count = ""
        self._reading = None
        self._preferred_column = None
        self.pending_register = None

    def undo(self) -> None:
        if not self._undo:
            return
        self._redo.append((self.text, self.selection))
        self.text, self.selection = self._undo.pop()
        self.clamp()

    def redo(self) -> None:
        if not self._redo:
            return
        self._undo.append((self.text, self.selection))
        self.text, self.selection = self._redo.pop()
        self.clamp()

    # ------------------------------------------------------------ dispatch  --

    def feed(self, key: str) -> ShellRequest | None:
        """Handle one canonical key token. See `keys.parse_keys`."""
        try:
            if self._reading is not None:
                return self._feed_reading(key)
            if self.mode is Mode.INSERT:
                return self._feed_insert(key)
            return self._feed_normal(key)
        finally:
            self.ensure_invariants()

    def feed_keys(self, keys) -> ShellRequest | None:
        """Feed a whole sequence, returning the last request produced."""
        from .keys import parse_keys

        if isinstance(keys, str):
            keys = parse_keys(keys)
        request = None
        for key in keys:
            request = self.feed(key) or request
        return request

    # -------------------------------------------------------- insert mode  --

    def _feed_insert(self, key: str) -> ShellRequest | None:
        if key == "<esc>":
            self.exit_insert()
            return None
        if key == "<ret>":
            return ShellRequest.ACCEPT
        if key == "<tab>":
            return ShellRequest.COMPLETE
        if key == "<backspace>":
            self._edit_each(
                lambda _i, rng: (
                    None
                    if self.caret_of(rng) == 0
                    else (self.caret_of(rng) - 1, self.caret_of(rng), "")
                )
            )
            return None
        if key == "<del>":
            self._edit_each(
                lambda _i, rng: (
                    None
                    if self.caret_of(rng) >= len(self.text)
                    else (self.caret_of(rng), self.caret_of(rng) + 1, "")
                )
            )
            return None
        if key in ("<left>", "<right>", "<home>", "<end>", "<up>", "<down>"):
            self.selection = self.selection.transform(
                lambda rng: Range(rng.anchor, self._insert_target(key, rng))
            )
            return None
        if is_printable(key):
            self._edit_each(
                lambda _i, rng: (self.caret_of(rng), self.caret_of(rng), key)
            )
            return None
        return None

    def _insert_target(self, key: str, rng: Range) -> int:
        """Where one caret goes for an arrow key pressed in insert mode."""
        caret = self.caret_of(rng)
        line = char_to_line(self.text, caret)
        start, end = line_bounds(self.text, line)
        target = {
            "<left>": max(caret - 1, 0),
            "<right>": min(caret + 1, len(self.text)),
            "<home>": start,
            "<end>": end,
        }.get(key)
        if target is None:  # up/down keep the anchor and just move the caret
            delta = -1 if key == "<up>" else 1
            new_line = max(0, min(line + delta, line_count(self.text) - 1))
            ns, ne = line_bounds(self.text, new_line)
            target = min(ns + (caret - start), ne)
        return target

    def exit_insert(self) -> None:
        """Leave insert mode.

        Helix leaves the selection alone here, with one exception: leaving
        *append* mode steps the head back a grapheme so the block cursor lands
        on the last character typed rather than past it. That is its
        `restore_cursor` flag, and only `a` sets it -- not `A`, not `I`, not
        `o`, not `c`. After those the cursor lands on whatever follows what was
        typed, which looks odd until you notice it is where the *caret* was.

        This port needs no step back of its own. Its insert-mode `head` is the
        caret itself where Helix keeps `head` one past it, so the two differ by
        exactly the grapheme `restore_cursor` subtracts: `a` already comes out
        agreeing. Everything else is left as it is -- including a bare caret,
        which stays a zero-width point until `ensure_invariants` widens it
        forwards onto the character it is sitting on.
        """
        self.mode = Mode.NORMAL
        self.ensure_invariants()

    def enter_insert(self, rng: Range) -> None:
        self.enter_insert_at(Selection.single(rng.anchor, rng.head))

    def enter_insert_at(self, selection: Selection) -> None:
        self._snapshot()
        self.mode = Mode.INSERT
        self.selection = selection

    # -------------------------------------------------- normal/select mode --

    def _feed_reading(self, key: str) -> ShellRequest | None:
        """One key of a regex being typed for `s`, `S`, `K` or `Alt-K`.

        The selection is re-derived on every keystroke, so what the pattern
        will do is on screen before Enter commits it -- which is the only
        reason typing a regex at a shell prompt is bearable. Enter keeps what
        is shown; Escape puts the original selection back.
        """
        reading = self._reading
        assert reading is not None
        if key == "<esc>":
            self._reading = None
            self.selection = reading.base
            return None
        if key == "<ret>":
            # Whatever the preview settled on *is* the answer: it was applied
            # to `base` on the last keystroke and is already the selection.
            self._reading = None
            return None
        if key == "<backspace>":
            if not reading.pattern:
                self._reading = None
                self.selection = reading.base
                return None
            reading.pattern = reading.pattern[:-1]
        elif is_printable(key):
            reading.pattern += key
        else:
            return None
        self._preview_reading()
        return None

    def _start_reading(self, kind: str) -> None:
        self._reading = _Reading(kind=kind, base=self.selection)

    def _preview_reading(self) -> None:
        reading = self._reading
        assert reading is not None
        base = reading.base
        if not reading.pattern:
            self.selection = base
            return
        try:
            pattern = re.compile(reading.pattern)
        except re.error:
            # Half a regex is not an error, it is a regex you are in the middle
            # of typing. `[a-` shows the selection unchanged and says nothing.
            self.selection = base
            return
        result = {
            "s": _select_matches,
            "S": _split_on_matches,
            "K": _keep_matching,
            "K!": _remove_matching,
        }[reading.kind](self.text, base, pattern)
        self.selection = base if result is None else result

    def _feed_normal(self, key: str) -> ShellRequest | None:
        if self._pending:
            return self._feed_pending(key)

        if key == "<esc>":
            self._count = ""
            if self.mode is Mode.SELECT:
                self.mode = Mode.NORMAL
            return None

        if key.isdigit() and (key != "0" or self._count):
            self._count += key
            return None

        try:
            return self._command(key)
        finally:
            if not self._pending:
                self._count = ""

    #: Keys that swallow the next keystroke whole rather than dispatching it.
    _ARG_PREFIXES = frozenset({"f", "F", "t", "T", "r", '"'})
    #: Keys that open a sub-keymap.
    _MENU_PREFIXES = frozenset({"g", "m", " "})

    def _feed_pending(self, key: str) -> ShellRequest | None:
        pending, self._pending = self._pending, ()
        try:
            if key == "<esc>":
                return None
            head = pending[0]
            if head in self._ARG_PREFIXES:
                return self._arg_command(head, key)
            if head == "g":
                return self._goto(key)
            if head == " ":
                return self._space(key)
            if head == "m":
                return self._match(pending[1:], key)
            return None
        finally:
            if not self._pending:
                self._count = ""

    def _command(self, key: str) -> ShellRequest | None:
        text, count, extend = self.text, self.count, self.extend

        if key in self._ARG_PREFIXES or key in self._MENU_PREFIXES:
            self._pending = (key,)
            return None

        # --- motion ------------------------------------------------------
        if key in ("h", "<left>", "<backspace>"):
            self._move_each(
                lambda rng: mv.move_horizontally(
                    text, rng, Direction.BACKWARD, count, extend
                )
            )
        elif key in ("l", "<right>"):
            self._move_each(
                lambda rng: mv.move_horizontally(
                    text, rng, Direction.FORWARD, count, extend
                )
            )
        elif key in ("j", "<down>"):
            return self._vertical(Direction.FORWARD, count, extend)
        elif key in ("k", "<up>"):
            return self._vertical(Direction.BACKWARD, count, extend)
        elif key in ("w", "W", "e", "E", "b", "B"):
            target = _WORD_TARGETS[key]
            self._move_each(lambda rng: mv.word_move(text, rng, count, target))
        elif key in ("<home>", "0"):
            self._move_each(lambda rng: mv.goto_line_start(text, rng, extend))
        elif key == "<end>":
            self._move_each(lambda rng: mv.goto_line_end(text, rng, extend))

        # --- selection ---------------------------------------------------
        elif key == "%":
            self.selection = Selection.single(0, len(text))
        elif key == "x":
            self._extend_line_below(count)
        elif key == "X":
            self._extend_to_line_bounds()
        elif key == ";":
            self.selection = self.selection.cursors(text)
        elif key == "v":
            self.mode = Mode.NORMAL if self.mode is Mode.SELECT else Mode.SELECT
        elif key == "_":
            self._trim_selection()

        # --- cursors -----------------------------------------------------
        elif key == ",":
            self.selection = self.selection.into_single()
        elif key == "C":
            self._copy_selection_on_line(Direction.FORWARD, count)
        elif key == ")":
            self.selection = self.selection.set_primary(
                self.selection.primary_index + count
            )
        elif key == "(":
            self.selection = self.selection.set_primary(
                self.selection.primary_index - count
            )
        elif key in ("s", "S", "K"):
            self._start_reading(key)

        # --- changes -----------------------------------------------------
        elif key == "i":
            self.enter_insert_at(
                self.selection.transform(lambda rng: Range(rng.end, rng.start))
            )
        elif key == "a":
            self.enter_insert_at(
                self.selection.transform(lambda rng: Range(rng.start, rng.end))
            )
        elif key == "I":
            self.enter_insert_at(
                self.selection.transform(
                    lambda rng: Range.point(self._first_nonblank(rng.cursor(text)))
                )
            )
        elif key == "A":
            self.enter_insert_at(
                self.selection.transform(
                    lambda rng: Range.point(
                        line_bounds(text, char_to_line(text, rng.cursor(text)))[1]
                    )
                )
            )
        elif key == "o":
            self._open_line(below=True)
        elif key == "O":
            self._open_line(below=False)
        elif key == "d":
            self._delete(yank=True)
        elif key == "c":
            self._change(yank=True)
        elif key == "y":
            self._yank()
        elif key == "p":
            self._paste(after=True)
        elif key == "P":
            self._paste(after=False)
        elif key == "R":
            self._replace_with_yank()
        elif key == "u":
            self.undo()
        elif key == "U":
            self.redo()
        elif key == "~":
            self._map_selection(_swap_case)
        elif key == "`":
            self._map_selection(str.lower)
        elif key == "J":
            self._join_lines()
        elif key == ">":
            self._indent(1)
        elif key == "<":
            self._indent(-1)

        # --- alt-prefixed ------------------------------------------------
        elif is_alt(key):
            return self._alt(alt_key(key))

        # --- shell -------------------------------------------------------
        elif key == "<ret>":
            return ShellRequest.ACCEPT
        elif key == "<tab>":
            return ShellRequest.COMPLETE

        return None

    def _alt(self, key: str) -> ShellRequest | None:
        text = self.text
        if key == ";":
            self.selection = self.selection.transform(Range.flip)
        elif key == ":":
            self.selection = self.selection.transform(
                lambda rng: rng.with_direction(Direction.FORWARD)
            )
        elif key == ".":
            if self._last_find is not None:
                find = self._last_find
                self._move_each(
                    lambda rng: mv.find_char(
                        text,
                        rng,
                        find.char,
                        self.count,
                        find.direction,
                        find.inclusive,
                        self.extend,
                    )
                )
        elif key == "d":
            self._delete(yank=False)
        elif key == "c":
            self._change(yank=False)
        elif key == "`":
            self._map_selection(str.upper)
        elif key == "J":
            self._join_lines()

        # --- cursors -----------------------------------------------------
        elif key == ",":
            self.selection = self.selection.remove(self.selection.primary_index)
        elif key == "C":
            self._copy_selection_on_line(Direction.BACKWARD, self.count)
        elif key == "K":
            self._start_reading("K!")
        elif key == "s":
            self.selection = self.selection.transform_iter(
                lambda rng: _split_on_newlines(text, rng)
            )
        elif key == "-":
            self.selection = self.selection.merge_ranges()
        elif key == "_":
            self.selection = self.selection.merge_consecutive()
        elif key == ")":
            self._rotate_contents(forward=True)
        elif key == "(":
            self._rotate_contents(forward=False)
        return None

    def _arg_command(self, prefix: str, key: str) -> ShellRequest | None:
        """`f`/`F`/`t`/`T`/`r`/`"` -- the second key is data, not a command."""
        if prefix == '"':
            if len(key) == 1:
                self.pending_register = key
            return None

        char = "\n" if key == "<ret>" else "\t" if key == "<tab>" else key
        if len(char) != 1:
            return None

        if prefix == "r":
            self._replace_chars(char)
            return None

        direction = Direction.FORWARD if prefix in "ft" else Direction.BACKWARD
        inclusive = prefix in "fF"
        self._last_find = _Find(char, direction, inclusive)
        text, count, extend = self.text, self.count, self.extend
        self._move_each(
            lambda rng: mv.find_char(
                text, rng, char, count, direction, inclusive, extend
            )
        )
        return None

    def _goto(self, key: str) -> ShellRequest | None:
        text, extend = self.text, self.extend
        # `gg` and `ge` go to one place, so they land on one cursor. The
        # within-the-line gotos keep every cursor, which is what makes `gh`
        # after a `C` column useful.
        if key == "g":
            line = int(self._count) if self._count else 1
            self.range = mv.goto_line(text, self.range, line, extend)
        elif key == "e":
            self.range = mv.goto_file_end(text, self.range, extend)
        elif key == "h":
            self._move_each(lambda rng: mv.goto_line_start(text, rng, extend))
        elif key == "l":
            self._move_each(lambda rng: mv.goto_line_end(text, rng, extend))
        elif key == "s":
            self._move_each(lambda rng: mv.goto_first_nonblank(text, rng, extend))
        return None

    def _space(self, key: str) -> ShellRequest | None:
        """The leader menu. Almost all of Helix's entries are editor features
        with no shell equivalent; the clipboard ones are the exception."""
        if key == "y":
            self._register_write("+", self.selection.fragments(self.text))
        elif key == "p":
            self._paste(after=True, register="+")
        elif key == "P":
            self._paste(after=False, register="+")
        elif key == "R":
            self._replace_with_yank(register="+")
        return None

    def _match(self, rest: tuple[str, ...], key: str) -> ShellRequest | None:
        """`m` -- bracket matching, surround and textobjects."""
        if not rest:
            if key == "m":
                text = self.text
                self._move_each(lambda rng: mv.match_bracket(text, rng))
            elif key in ("i", "a", "s", "d", "r"):
                self._pending = ("m", key)
            return None

        action = rest[0]
        if action in ("i", "a"):
            self._select_textobject(key, around=action == "a")
        elif action == "s":
            self._surround_add(key)
        elif action == "d":
            self._surround_delete(key)
        elif action == "r":
            if len(rest) == 1:
                self._pending = ("m", "r", key)
            else:
                self._surround_replace(rest[1], key)
        return None

    # ------------------------------------------------------------- motions --

    def _move_each(self, fn: Callable[[Range], Range]) -> None:
        """Apply a motion to every cursor. What every motion key does."""
        self.selection = self.selection.transform(fn)
        self._preferred_column = None

    def _vertical(
        self, direction: Direction, count: int, extend: bool
    ) -> ShellRequest | None:
        # A one-line buffer is the overwhelmingly common case at a prompt, and
        # there `j`/`k` have nowhere to go -- so they walk history instead,
        # which is what every other shell's normal mode does.
        if line_count(self.text) == 1:
            return (
                ShellRequest.HISTORY_NEXT
                if direction is Direction.FORWARD
                else ShellRequest.HISTORY_PREV
            )
        # One preferred column for all the cursors, taken from the primary.
        # Helix keeps one per range; here that would mean threading a column
        # through `Selection`, for a case -- several cursors on a multi-line
        # command, moved vertically over lines of differing length -- that a
        # shell prompt does not really have.
        column = self._preferred_column
        moved = [
            mv.move_vertically(self.text, rng, direction, count, extend, column)
            for rng in self.selection
        ]
        primary = self.selection.primary_index
        self.selection = Selection(tuple(rng for rng, _ in moved), primary).normalize()
        self._preferred_column = moved[primary][1]
        return None

    def _first_nonblank(self, pos: int) -> int:
        start, end = line_bounds(self.text, char_to_line(self.text, pos))
        while start < end and self.text[start] in " \t":
            start += 1
        return start

    def _extend_line_below(self, count: int) -> None:
        text = self.text

        def extend(rng: Range) -> Range:
            start_line, end_line = rng.line_range(text)
            start = line_to_char(text, start_line)
            _, line_end = line_bounds(text, end_line)
            end = min(line_end + 1, len(text))

            already_whole = rng.start == start and rng.end == end
            extra = count - 1 + (1 if already_whole else 0)
            if extra:
                end_line = min(end_line + extra, line_count(text) - 1)
                _, line_end = line_bounds(text, end_line)
                end = min(line_end + 1, len(text))
            return Range(start, end)

        self.selection = self.selection.transform(extend)

    def _extend_to_line_bounds(self) -> None:
        text = self.text

        def extend(rng: Range) -> Range:
            start_line, end_line = rng.line_range(text)
            _, line_end = line_bounds(text, end_line)
            return Range(line_to_char(text, start_line), min(line_end + 1, len(text)))

        self.selection = self.selection.transform(extend)

    def _trim_selection(self) -> None:
        text = self.text

        def trim(rng: Range) -> list[Range]:
            start, end = rng.start, rng.end
            while start < end and text[start].isspace():
                start += 1
            while end > start and text[end - 1].isspace():
                end -= 1
            # All whitespace: Helix drops the range rather than leaving a
            # cursor sitting on a space it was told to trim away.
            if start == end:
                return []
            forward = rng.direction is Direction.FORWARD
            return [Range(start, end) if forward else Range(end, start)]

        self.selection = self.selection.transform_iter(trim)

    # ------------------------------------------------------------- cursors --

    def _copy_selection_on_line(self, direction: Direction, count: int) -> None:
        """`C` and `Alt-C` -- the same selection again on the line below/above.

        Skips lines too short to hold it, which is what stops a column of
        cursors from bunching up at the ends of ragged lines. Columns are
        counted in characters rather than display cells; see the module
        docstring.
        """
        text = self.text
        lines = line_count(text)
        primary = self.selection.primary
        result: list[Range] = []
        primary_at = 0

        for rng in self.selection:
            is_primary = rng == primary
            if is_primary:
                primary_at = len(result)
            result.append(rng)

            # Both ends as inclusive positions, so a one-wide block cursor is
            # one column rather than a column and its right-hand gap.
            if rng.anchor < rng.head:
                head, anchor = rng.head - 1, rng.anchor
            else:
                head, anchor = rng.head, max(rng.anchor - 1, 0)
            head_line, head_col = _coords(text, head)
            anchor_line, anchor_col = _coords(text, anchor)
            height = abs(head_line - anchor_line) + 1

            made = 0
            step = 0
            while made < count:
                offset = (step + 1) * height
                if direction is Direction.FORWARD:
                    to_anchor, to_head = anchor_line + offset, head_line + offset
                else:
                    if anchor_line < offset or head_line < offset:
                        break
                    to_anchor, to_head = anchor_line - offset, head_line - offset
                if to_anchor >= lines or to_head >= lines:
                    break

                at_anchor = _pos_at(text, to_anchor, anchor_col)
                at_head = _pos_at(text, to_head, head_col)
                if (
                    _coords(text, at_anchor)[1] == anchor_col
                    and _coords(text, at_head)[1] == head_col
                ):
                    if is_primary:
                        primary_at = len(result)
                    result.append(
                        Range.point(at_anchor).put_cursor(text, at_head, True)
                    )
                    made += 1
                if to_anchor == 0 and to_head == 0:
                    break
                step += 1

        self.selection = Selection(tuple(result), primary_at).normalize()

    def _rotate_contents(self, *, forward: bool) -> None:
        """`Alt-)` / `Alt-(` -- move the text between the cursors along."""
        selection = self.selection
        if not selection.multi:
            return
        fragments = selection.fragments(self.text)
        total = len(fragments)
        by = self.count % total
        if by == 0:
            return
        if forward:
            rotated = fragments[-by:] + fragments[:-by]
            primary = (selection.primary_index + by) % total
        else:
            rotated = fragments[by:] + fragments[:by]
            primary = (selection.primary_index - by) % total
        self._snapshot()
        written = self._edit_each(
            lambda i, rng: (rng.start, rng.end, rotated[i]), widen=True
        )
        if written is not None:
            self.selection = written.set_primary(primary)

    # ------------------------------------------------------------- editing --

    def _splice(self, edits: list[Edit]) -> None:
        """The mutation primitive: apply a batch of edits, carry every range.

        Every edit names positions in the text as it is *now*, so a command can
        work out what it wants to do at each of ten cursors before any of it
        happens. They are applied together and every range in the selection is
        mapped through the lot.

        A position sitting exactly on a pure *insertion* moves to the far side
        of the inserted text -- Helix's `Assoc::After`. That is what makes the
        caret advance as you type and what makes `>` push the selection right
        along with the line it indents. A position on the start of a
        *replacement* stays put instead, or `mr([` would drag the cursor off the
        character it was on and onto the new bracket.
        """
        if not edits:
            return
        ordered = sorted(edits, key=lambda edit: (edit[0], edit[1]))

        parts: list[str] = []
        applied: list[Edit] = []
        at = 0
        for start, end, replacement in ordered:
            if start < at:
                # Two edits over the same characters. Ranges are non-overlapping
                # by construction, so this means a command built them wrongly;
                # dropping the later one keeps the text coherent either way.
                continue
            parts.append(self.text[at:start])
            parts.append(replacement)
            at = end
            applied.append((start, end, replacement))
        parts.append(self.text[at:])
        self.text = "".join(parts)

        moved = _positions_after(
            applied,
            [end for rng in self.selection for end in (rng.anchor, rng.head)],
        )
        self.selection = self.selection.transform(
            lambda rng: Range(moved[rng.anchor], moved[rng.head])
        )
        self.clamp()

    def _replace(self, start: int, end: int, replacement: str) -> None:
        """One edit. `_splice` with the batch spelled out."""
        self._splice([(start, end, replacement)])

    def _edit_each(
        self,
        make: Callable[[int, Range], Edit | None],
        *,
        widen: bool = False,
    ) -> Selection | None:
        """One edit per cursor, and a selection over what was written.

        `make(index, range)` returns an edit or `None` to leave that cursor
        alone. Every call sees the text unchanged, and the returned selection
        is in terms of the text *after* -- which is what `d`, `r`, `p` and `~`
        all want, because each of them ends by selecting what it just put
        there. `widen` applies the block-cursor minimum, for the commands that
        write nothing and leave a bare caret behind.

        `None` when no cursor produced an edit, so a caller can tell "nothing
        to do" from "wrote an empty string everywhere".
        """
        selection = self.selection
        primary_index = selection.primary_index

        numbered: list[tuple[int, int, int, str]] = []
        for index, rng in enumerate(selection):
            edit = make(index, rng)
            if edit is not None:
                numbered.append((index, *edit))
        if not numbered:
            return None
        numbered.sort(key=lambda item: (item[1], item[2]))

        written: list[Range] = []
        primary_at = 0
        delta = 0
        for index, start, end, replacement in numbered:
            if index == primary_index:
                primary_at = len(written)
            written.append(Range(start + delta, start + delta + len(replacement)))
            delta += len(replacement) - (end - start)

        self._splice([(start, end, text) for _, start, end, text in numbered])

        if widen:
            written = [rng.min_width_1(self.text) for rng in written]
        return Selection(tuple(written), min(primary_at, len(written) - 1)).normalize()

    def adopt_text(self, new_text: str) -> None:
        """Take on text edited by something else, moving the range with it.

        The integration layer leaves insert-mode typing to prompt_toolkit, so
        the editor finds out about it after the fact. Diffing to a single splice
        and pushing it through `_replace` is what keeps the anchor behaving
        exactly as it does when the editor makes the edit itself -- Helix moves
        the selection through the change set for the same reason.
        """
        old = self.text
        if old == new_text:
            return
        limit = min(len(old), len(new_text))
        prefix = 0
        while prefix < limit and old[prefix] == new_text[prefix]:
            prefix += 1
        suffix = 0
        while (
            suffix < limit - prefix
            and old[len(old) - 1 - suffix] == new_text[len(new_text) - 1 - suffix]
        ):
            suffix += 1
        self._replace(
            prefix, len(old) - suffix, new_text[prefix : len(new_text) - suffix]
        )

    def _delete(self, *, yank: bool) -> None:
        if all(rng.is_empty for rng in self.selection):
            return
        self._snapshot()
        if yank:
            self._register_write(
                self.pending_register, self.selection.fragments(self.text)
            )
            self.pending_register = None
        written = self._edit_each(
            lambda _i, rng: None if rng.is_empty else (rng.start, rng.end, ""),
            widen=True,
        )
        if written is not None:
            self.selection = written
        if self.mode is Mode.SELECT:
            self.mode = Mode.NORMAL

    def _change(self, *, yank: bool) -> None:
        """`c` -- delete, then leave a caret where each selection was."""
        self._delete(yank=yank)
        self.enter_insert_at(
            self.selection.transform(lambda rng: Range.point(rng.start))
        )

    def _yank(self) -> None:
        self._register_write(self.pending_register, self.selection.fragments(self.text))
        self.pending_register = None
        if self.mode is Mode.SELECT:
            self.mode = Mode.NORMAL

    def _paste(self, *, after: bool, register: str | None = None) -> None:
        values = self._register_read(register or self.pending_register)
        self.pending_register = None
        if not any(values):
            return
        self._snapshot()
        text = self.text
        # Line-wise if *anything* in the register ended on a newline: a yank
        # that swallowed one pastes as whole lines, never into the middle of a
        # line, and a mixed register would otherwise paste inconsistently.
        linewise = any(value.endswith("\n") for value in values)

        def make(index: int, rng: Range) -> Edit | None:
            # Fewer values than cursors: the last one repeats, so yanking one
            # thing and pasting it at every cursor works.
            value = values[index] if index < len(values) else values[-1]
            if not value:
                return None
            if linewise:
                start_line, end_line = rng.line_range(text)
                if after:
                    _, line_end = line_bounds(text, end_line)
                    at = min(line_end + 1, len(text))
                    if at == len(text) and not text.endswith("\n"):
                        # No newline to paste after, so make one and drop the
                        # trailing one instead of leaving a blank last line.
                        return (at, at, "\n" + value[:-1])
                else:
                    at = line_to_char(text, start_line)
            else:
                at = rng.end if after else rng.start
            return (at, at, value)

        written = self._edit_each(make)
        if written is not None:
            self.selection = written
        if self.mode is Mode.SELECT:
            self.mode = Mode.NORMAL

    def _replace_with_yank(self, register: str | None = None) -> None:
        values = self._register_read(register or self.pending_register)
        self.pending_register = None
        if not any(values):
            return
        self._snapshot()
        written = self._edit_each(
            lambda index, rng: (
                rng.start,
                rng.end,
                values[index] if index < len(values) else values[-1],
            ),
            widen=True,
        )
        if written is not None:
            self.selection = written

    def _replace_chars(self, char: str) -> None:
        text = self.text
        if all(rng.min_width_1(text).is_empty for rng in self.selection):
            return
        self._snapshot()

        def make(_index: int, rng: Range) -> Edit | None:
            rng = rng.min_width_1(text)
            if rng.is_empty:
                return None
            # Every character goes, newlines included -- Helix's `replace` maps
            # each grapheme in the range without looking at what it is, so a
            # multi-line selection really does collapse onto one line.
            return (rng.start, rng.end, char * len(rng.slice(text)))

        written = self._edit_each(make)
        if written is not None:
            self.selection = written

    def _map_selection(self, fn) -> None:
        text = self.text
        if all(rng.min_width_1(text).is_empty for rng in self.selection):
            return
        self._snapshot()

        def make(_index: int, rng: Range) -> Edit | None:
            rng = rng.min_width_1(text)
            if rng.is_empty:
                return None
            return (rng.start, rng.end, fn(rng.slice(text)))

        written = self._edit_each(make)
        if written is not None:
            self.selection = written

    def _open_line(self, *, below: bool) -> None:
        text = self.text
        self._snapshot()
        self.mode = Mode.INSERT

        def make(_index: int, rng: Range) -> Edit:
            line = char_to_line(text, rng.cursor(text))
            start, end = line_bounds(text, line)
            indent = text[start : self._first_nonblank(start)]
            if below:
                return (end, end, "\n" + indent)
            return (start, start, indent + "\n")

        written = self._edit_each(make)
        if written is not None:
            # `o` leaves the caret at the end of what it wrote -- past the
            # newline, on the indent. `O` leaves it just before the newline,
            # which is the end of the line it just made.
            self.selection = written.transform(
                lambda rng: Range.point(rng.end if below else rng.end - 1)
            )

    def _join_lines(self) -> None:
        text = self.text
        last = line_count(text) - 1
        targets: set[int] = set()
        for rng in self.selection:
            start_line, end_line = rng.line_range(text)
            if end_line == start_line:
                end_line += 1
            targets.update(range(start_line, min(end_line, last)))
        if not targets:
            return
        self._snapshot()
        # All the joins in one batch rather than one at a time: computed
        # against the original text, they cannot disturb each other's
        # positions, and two cursors on the same line ask for the same join
        # exactly once.
        edits: list[Edit] = []
        for line in sorted(targets):
            _, end = line_bounds(text, line)
            nxt = end + 1
            while nxt < len(text) and text[nxt] in " \t":
                nxt += 1
            edits.append((end, nxt, " "))
        self._splice(edits)

    def _indent(self, sign: int) -> None:
        text = self.text
        lines: set[int] = set()
        for rng in self.selection:
            start_line, end_line = rng.line_range(text)
            lines.update(range(start_line, end_line + 1))
        self._snapshot()
        edits: list[Edit] = []
        for line in sorted(lines):
            start, _ = line_bounds(text, line)
            if sign > 0:
                edits.append((start, start, INDENT))
                continue
            width = 0
            while (
                width < len(INDENT)
                and start + width < len(text)
                and text[start + width] == " "
            ):
                width += 1
            if width:
                edits.append((start, start + width, ""))
        self._splice(edits)

    # ---------------------------------------------------- surround/objects --

    def _select_textobject(self, kind: str, *, around: bool) -> None:
        text = self.text

        def select(rng: Range) -> list[Range]:
            pos = rng.cursor(text)
            if kind in ("w", "W"):
                start, end = _word_bounds(text, pos, long=kind == "W")
                if around:
                    while end < len(text) and text[end] in " \t":
                        end += 1
                return [Range(start, end)]
            pair = _pair_for(kind)
            if pair is None:
                return [rng]
            found = _find_enclosing(text, pos, *pair)
            if found is None:
                return [rng]
            open_idx, close_idx = found
            if around:
                return [Range(open_idx, close_idx + 1)]
            return [Range(open_idx + 1, close_idx)]

        self.selection = self.selection.transform_iter(select)

    def _surround_add(self, kind: str) -> None:
        pair = _pair_for(kind)
        if pair is None:
            return
        open_ch, close_ch = pair
        self._snapshot()
        text = self.text
        edits: list[Edit] = []
        wrapped: list[Range] = []
        delta = 0
        # In selection order, which is sorted, so the running offset is just
        # the two characters each earlier cursor added.
        for rng in self.selection:
            rng = rng.min_width_1(text)
            edits.append((rng.start, rng.start, open_ch))
            edits.append((rng.end, rng.end, close_ch))
            wrapped.append(Range(rng.start + delta, rng.end + delta + 2))
            delta += 2
        primary = self.selection.primary_index
        self._splice(edits)
        self.selection = Selection(tuple(wrapped), primary).normalize()

    def _surround_delete(self, kind: str) -> None:
        pair = _pair_for(kind)
        if pair is None:
            return
        self._surround_edit(pair, ("", ""))

    def _surround_replace(self, old: str, new: str) -> None:
        old_pair, new_pair = _pair_for(old), _pair_for(new)
        if old_pair is None or new_pair is None:
            return
        self._surround_edit(old_pair, new_pair)

    def _surround_edit(
        self, pair: tuple[str, str], replacement: tuple[str, str]
    ) -> None:
        """Rewrite the brackets around every cursor. `md` and `mr`.

        Two cursors inside the same pair ask for the same edit, so the pairs
        are collected into a set first -- without that the second cursor's
        edit would be dropped by `_splice` as an overlap and the result would
        depend on how many cursors happened to be in there.

        No explicit reselect: the ranges are carried through the change, which
        is what keeps each cursor on the character it was on.
        """
        found = set()
        for rng in self.selection:
            enclosing = _find_enclosing(self.text, rng.cursor(self.text), *pair)
            if enclosing is not None:
                found.add(enclosing)
        if not found:
            return
        self._snapshot()
        edits: list[Edit] = []
        for open_idx, close_idx in sorted(found):
            edits.append((open_idx, open_idx + 1, replacement[0]))
            edits.append((close_idx, close_idx + 1, replacement[1]))
        self._splice(edits)


def _positions_after(applied: list[Edit], positions: list[int]) -> dict[int, int]:
    """Where each of `positions` ends up once `applied` has been applied.

    `applied` is sorted and non-overlapping, so this walks both sequences once
    together rather than rescanning the edits per position. That is not a
    micro-optimisation: `s` on a long line puts a cursor on every match, and the
    obvious version is O(cursors x edits) with one edit per cursor -- a keystroke
    at a thousand cursors took ninety milliseconds, which is a shell that feels
    broken without ever being wrong. Helix says the same thing about its own
    `Range::map`, and points at `Selection::map` for the same reason.

    The rule per edit, and the whole of what the batch means:

    * before it, or exactly on the start of a *replacement* -- stay put. That
      second half is what keeps `mr([` from dragging the cursor off the
      character it was on and onto the new bracket.
    * exactly on a pure *insertion* -- move to the far side of the inserted
      text, Helix's `Assoc::After`. This is what makes the caret advance as you
      type, and what makes `>` push the selection along with the line.
    * inside it -- collapse onto the end of what replaced it.
    * after it -- shift by what it changed in length.
    """
    moved: dict[int, int] = {}
    index = 0
    delta = 0
    for pos in sorted(set(positions)):
        while index < len(applied):
            start, end, replacement = applied[index]
            if pos < start or (pos == start and start != end) or pos < end:
                break
            delta += len(replacement) - (end - start)
            index += 1
        if index < len(applied):
            start, end, replacement = applied[index]
            if start < pos < end:
                moved[pos] = start + len(replacement) + delta
                continue
        moved[pos] = pos + delta
    return moved


#: `w`/`W`/`e`/`E`/`b`/`B`, which differ only in which boundary they look for.
_WORD_TARGETS = {
    "w": mv.WordTarget.NEXT_WORD_START,
    "W": mv.WordTarget.NEXT_LONG_WORD_START,
    "e": mv.WordTarget.NEXT_WORD_END,
    "E": mv.WordTarget.NEXT_LONG_WORD_END,
    "b": mv.WordTarget.PREV_WORD_START,
    "B": mv.WordTarget.PREV_LONG_WORD_START,
}


def _coords(text: str, pos: int) -> tuple[int, int]:
    """`(line, column)` for a character index, counted in characters."""
    line = char_to_line(text, pos)
    return line, pos - line_to_char(text, line)


def _pos_at(text: str, line: int, column: int) -> int:
    """The index at `(line, column)`, clamped to the end of that line."""
    start, end = line_bounds(text, line)
    return min(start + column, end)


def _select_matches(
    text: str, selection: Selection, pattern: re.Pattern
) -> Selection | None:
    """`s` -- every match of `pattern` inside the selection, as its own cursor.

    `None` when nothing matched, which the caller shows as the selection
    unchanged rather than as an error: half a typed regex matches nothing most
    of the way through being typed.
    """
    found: list[Range] = []
    for rng in selection:
        offset = rng.start
        for match in pattern.finditer(rng.slice(text)):
            # Zero-width matches would each become a bare caret and there can
            # be one between every pair of characters, so `.*` would select
            # nothing an unbounded number of times.
            if match.end() > match.start():
                found.append(Range(offset + match.start(), offset + match.end()))
    return Selection.of(found) if found else None


def _split_on_matches(
    text: str, selection: Selection, pattern: re.Pattern
) -> Selection | None:
    """`S` -- what is *between* the matches, as separate cursors."""
    found: list[Range] = []
    for rng in selection:
        if rng.is_empty:
            found.append(rng)
            continue
        at = rng.start
        for match in pattern.finditer(rng.slice(text)):
            if match.end() == match.start():
                continue
            end = rng.start + match.start()
            if end > at:
                found.append(Range(at, end))
            at = rng.start + match.end()
        if at < rng.end:
            found.append(Range(at, rng.end))
    return Selection.of(found) if found else None


def _split_on_newlines(text: str, rng: Range) -> list[Range]:
    """`Alt-s` -- one cursor per line the range covers."""
    if rng.is_empty:
        return [rng]
    pieces: list[Range] = []
    at = rng.start
    while True:
        nxt = text.find("\n", at, rng.end)
        if nxt == -1:
            break
        if nxt > at:
            pieces.append(Range(at, nxt))
        at = nxt + 1
    if at < rng.end:
        pieces.append(Range(at, rng.end))
    return pieces or [rng]


def _keep_matching(
    text: str, selection: Selection, pattern: re.Pattern
) -> Selection | None:
    """`K` -- drop the cursors whose selection does not match."""
    kept = [rng for rng in selection if pattern.search(rng.slice(text))]
    return Selection.of(kept) if kept else None


def _remove_matching(
    text: str, selection: Selection, pattern: re.Pattern
) -> Selection | None:
    """`Alt-K` -- drop the cursors whose selection does match."""
    kept = [rng for rng in selection if not pattern.search(rng.slice(text))]
    return Selection.of(kept) if kept else None


def _swap_case(chunk: str) -> str:
    return chunk.swapcase()


_PAIRS = {
    "(": ("(", ")"),
    ")": ("(", ")"),
    "b": ("(", ")"),
    "[": ("[", "]"),
    "]": ("[", "]"),
    "{": ("{", "}"),
    "}": ("{", "}"),
    "B": ("{", "}"),
    "<": ("<", ">"),
    ">": ("<", ">"),
    '"': ('"', '"'),
    "'": ("'", "'"),
    "`": ("`", "`"),
}


def _pair_for(kind: str) -> tuple[str, str] | None:
    return _PAIRS.get(kind)


def _word_bounds(text: str, pos: int, *, long: bool) -> tuple[int, int]:
    from .chars import CharCategory, categorize_char

    if not text:
        return 0, 0
    pos = min(pos, len(text) - 1)

    def same(a: str, b: str) -> bool:
        if long:
            return not a.isspace() and not b.isspace()
        return categorize_char(a) is categorize_char(b)

    if categorize_char(text[pos]) in (CharCategory.WHITESPACE, CharCategory.EOL):
        return pos, pos + 1
    start = pos
    while start > 0 and same(text[start - 1], text[pos]):
        start -= 1
    end = pos + 1
    while end < len(text) and same(text[end], text[pos]):
        end += 1
    return start, end


def _find_enclosing(
    text: str, pos: int, open_ch: str, close_ch: str
) -> tuple[int, int] | None:
    """Innermost `open_ch`..`close_ch` pair containing `pos`."""
    if open_ch == close_ch:
        # Quotes have no nesting to count, so pair them off from the start of
        # the line and take whichever pair straddles the cursor.
        line = char_to_line(text, pos)
        start, end = line_bounds(text, line)
        marks = [i for i in range(start, end) if text[i] == open_ch]
        for left, right in zip(marks[0::2], marks[1::2]):
            if left <= pos <= right:
                return left, right
        return None

    depth = 0
    open_idx = None
    for i in range(pos, -1, -1):
        if text[i] == close_ch and i != pos:
            depth += 1
        elif text[i] == open_ch:
            if depth == 0:
                open_idx = i
                break
            depth -= 1
    if open_idx is None:
        return None
    close_idx = mv._find_close(text, open_idx, open_ch, close_ch)
    if close_idx is None or close_idx < pos:
        return None
    return open_idx, close_idx


def next_grapheme_of(text: str, pos: int) -> int:  # re-export for the ptk layer
    return next_grapheme(text, pos)
