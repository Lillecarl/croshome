"""Motions, ported from helix-core/src/movement.rs and search.rs.

Every function here takes `(text, range, ...)` and returns a new `Range`. None
of them touch the text, and none of them know about prompt_toolkit -- which is
what makes the whole keymap testable without a terminal.
"""

from __future__ import annotations

from enum import Enum

from .chars import char_is_line_ending, is_long_word_boundary, is_word_boundary
from .selection import (
    Direction,
    Range,
    char_to_line,
    line_bounds,
    line_count,
    line_to_char,
    next_grapheme,
    nth_next_grapheme,
    nth_prev_grapheme,
    prev_grapheme,
)


class WordTarget(Enum):
    NEXT_WORD_START = "next_word_start"
    NEXT_WORD_END = "next_word_end"
    PREV_WORD_START = "prev_word_start"
    PREV_WORD_END = "prev_word_end"
    NEXT_LONG_WORD_START = "next_long_word_start"
    NEXT_LONG_WORD_END = "next_long_word_end"
    PREV_LONG_WORD_START = "prev_long_word_start"
    PREV_LONG_WORD_END = "prev_long_word_end"


_PREV_TARGETS = frozenset(
    {
        WordTarget.PREV_WORD_START,
        WordTarget.PREV_WORD_END,
        WordTarget.PREV_LONG_WORD_START,
        WordTarget.PREV_LONG_WORD_END,
    }
)


def move_horizontally(
    text: str, rng: Range, direction: Direction, count: int, extend: bool
) -> Range:
    pos = rng.cursor(text)
    if direction is Direction.FORWARD:
        new_pos = nth_next_grapheme(text, pos, count)
    else:
        new_pos = nth_prev_grapheme(text, pos, count)
    return rng.put_cursor(text, new_pos, extend)


def move_vertically(
    text: str,
    rng: Range,
    direction: Direction,
    count: int,
    extend: bool,
    preferred_column: int | None = None,
) -> tuple[Range, int]:
    """Move by line, keeping a preferred column across short lines.

    Returns the new range *and* the column to remember, because that column has
    to survive a `j` over a short line -- storing it on the `Range` (as Helix
    does) would make ranges compare unequal in tests for a reason the test is
    not about.
    """
    pos = rng.cursor(text)
    line = char_to_line(text, pos)
    column = pos - line_to_char(text, line)
    if preferred_column is not None:
        column = max(column, preferred_column)

    if direction is Direction.FORWARD:
        new_line = min(line + count, line_count(text) - 1)
    else:
        new_line = max(line - count, 0)

    start, end = line_bounds(text, new_line)
    new_pos = min(start + column, end)
    return rng.put_cursor(text, new_pos, extend), column


def _reached_target(target: WordTarget, prev_ch: str, next_ch: str) -> bool:
    if target in (WordTarget.NEXT_WORD_START, WordTarget.PREV_WORD_END):
        return is_word_boundary(prev_ch, next_ch) and (
            char_is_line_ending(next_ch) or not next_ch.isspace()
        )
    if target in (WordTarget.NEXT_WORD_END, WordTarget.PREV_WORD_START):
        return is_word_boundary(prev_ch, next_ch) and (
            not prev_ch.isspace() or char_is_line_ending(next_ch)
        )
    if target in (WordTarget.NEXT_LONG_WORD_START, WordTarget.PREV_LONG_WORD_END):
        return is_long_word_boundary(prev_ch, next_ch) and (
            char_is_line_ending(next_ch) or not next_ch.isspace()
        )
    # NEXT_LONG_WORD_END | PREV_LONG_WORD_START
    return is_long_word_boundary(prev_ch, next_ch) and (
        not prev_ch.isspace() or char_is_line_ending(next_ch)
    )


def _range_to_target(text: str, target: WordTarget, origin: Range) -> Range:
    """One step of a word motion.

    A direct port of `CharHelpers::range_to_target`. Helix walks a bidirectional
    character iterator; here the same walk is expressed over indices, with
    `_read` standing in for "the character the iterator would yield next".
    """
    is_prev = target in _PREV_TARGETS
    step = -1 if is_prev else 1

    def read(idx: int) -> str | None:
        """The character the iterator yields when its gap index is `idx`."""
        i = idx - 1 if is_prev else idx
        return text[i] if 0 <= i < len(text) else None

    def peek_back(idx: int) -> str | None:
        """The character *behind* the iterator -- Helix's `chars.prev()` peek."""
        i = idx if is_prev else idx - 1
        return text[i] if 0 <= i < len(text) else None

    anchor = origin.anchor
    head = origin.head
    prev_ch = peek_back(head)

    # Skip any initial line endings, so `w` at the end of a line lands on the
    # first word of the next one rather than on the newline itself.
    while True:
        ch = read(head)
        if ch is not None and char_is_line_ending(ch):
            prev_ch = ch
            head += step
        else:
            break
    if prev_ch is not None and char_is_line_ending(prev_ch):
        anchor = head

    head_start = head
    while True:
        next_ch = read(head)
        if next_ch is None:
            break
        if prev_ch is None or _reached_target(target, prev_ch, next_ch):
            if head == head_start:
                anchor = head
            else:
                break
        prev_ch = next_ch
        head += step

    return Range(anchor, head)


def word_move(text: str, rng: Range, count: int, target: WordTarget) -> Range:
    is_prev = target in _PREV_TARGETS

    if (is_prev and rng.head == 0) or (not is_prev and rng.head == len(text)):
        return rng

    # Normalise the starting range so the block cursor -- not the anchor --
    # decides where the walk begins. Helix does this so that `w` from a wide
    # selection behaves the same as `w` from a bare cursor.
    if is_prev:
        if rng.anchor < rng.head:
            start = Range(rng.head, prev_grapheme(text, rng.head))
        else:
            start = Range(next_grapheme(text, rng.head), rng.head)
    else:
        if rng.anchor < rng.head:
            start = Range(prev_grapheme(text, rng.head), rng.head)
        else:
            start = Range(rng.head, next_grapheme(text, rng.head))

    current = start
    for _ in range(count):
        nxt = _range_to_target(text, target, current)
        if nxt == current:
            break
        current = nxt
    return current


def find_nth_char(
    text: str, ch: str, pos: int, n: int, direction: Direction
) -> int | None:
    """Index of the nth `ch` at or after `pos` (forward) / before `pos` (backward)."""
    if n == 0 or pos > len(text) or pos < 0:
        return None
    if direction is Direction.FORWARD:
        i = pos
        while i < len(text):
            if text[i] == ch:
                n -= 1
                if n == 0:
                    return i
            i += 1
        return None
    i = pos - 1
    while i >= 0:
        if text[i] == ch:
            n -= 1
            if n == 0:
                return i
        i -= 1
    return None


def find_char(
    text: str,
    rng: Range,
    ch: str,
    count: int,
    direction: Direction,
    inclusive: bool,
    extend: bool,
) -> Range:
    """`f`/`F`/`t`/`T`.

    Unlike Vim these are not confined to the current line, which is deliberate
    upstream behaviour and useful on a multi-line command.
    """
    cursor_anchor = rng.cursor(text)
    cursor_head = next_grapheme(text, cursor_anchor)

    # Exclusive search starts one further out, so that repeating `t` makes
    # progress instead of matching the character it already stopped before.
    if inclusive:
        start = cursor_head if direction is Direction.FORWARD else cursor_anchor
    else:
        start = (
            cursor_head + 1
            if direction is Direction.FORWARD
            else max(cursor_anchor - 1, 0)
        )

    found = find_nth_char(text, ch, start, count, direction)
    if found is None:
        return rng
    if not inclusive:
        found = found - 1 if direction is Direction.FORWARD else found + 1

    if extend:
        return rng.put_cursor(text, found, True)
    return Range.point(rng.cursor(text)).put_cursor(text, found, True)


def goto_line_start(text: str, rng: Range, extend: bool) -> Range:
    line = char_to_line(text, rng.cursor(text))
    return rng.put_cursor(text, line_to_char(text, line), extend)


def goto_line_end(text: str, rng: Range, extend: bool) -> Range:
    line = char_to_line(text, rng.cursor(text))
    _, end = line_bounds(text, line)
    return rng.put_cursor(text, max(end - 1, line_to_char(text, line)), extend)


def goto_first_nonblank(text: str, rng: Range, extend: bool) -> Range:
    line = char_to_line(text, rng.cursor(text))
    start, end = line_bounds(text, line)
    pos = start
    while pos < end and text[pos] in " \t":
        pos += 1
    return rng.put_cursor(text, min(pos, max(end - 1, start)), extend)


def goto_line(text: str, rng: Range, line: int, extend: bool) -> Range:
    """1-based, like `:goto`. Lands on the first non-blank of the line."""
    line = max(0, min(line - 1, line_count(text) - 1))
    start, end = line_bounds(text, line)
    pos = start
    while pos < end and text[pos] in " \t":
        pos += 1
    return rng.put_cursor(text, min(pos, max(end - 1, start)), extend)


def goto_file_end(text: str, rng: Range, extend: bool) -> Range:
    return rng.put_cursor(text, prev_grapheme(text, len(text)), extend)


_BRACKETS = {"(": ")", "[": "]", "{": "}", "<": ">"}
_CLOSERS = {v: k for k, v in _BRACKETS.items()}


def match_bracket(text: str, rng: Range) -> Range:
    """`mm` -- jump to the bracket matching the one under the cursor.

    If the cursor is not on a bracket, Helix looks forward on the line for the
    nearest one first; this does the same.
    """
    pos = rng.cursor(text)
    line = char_to_line(text, pos)
    _, line_end = line_bounds(text, line)

    scan = pos
    while (
        scan < line_end and text[scan] not in _BRACKETS and text[scan] not in _CLOSERS
    ):
        scan += 1
    if scan >= line_end or scan >= len(text):
        return rng

    ch = text[scan]
    if ch in _BRACKETS:
        target = _find_close(text, scan, ch, _BRACKETS[ch])
    else:
        target = _find_open(text, scan, _CLOSERS[ch], ch)
    if target is None:
        return rng
    return Range.point(target).put_cursor(text, target, True)


def _find_close(text: str, start: int, open_ch: str, close_ch: str) -> int | None:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return None


def _find_open(text: str, start: int, open_ch: str, close_ch: str) -> int | None:
    depth = 0
    for i in range(start, -1, -1):
        if text[i] == close_ch:
            depth += 1
        elif text[i] == open_ch:
            depth -= 1
            if depth == 0:
                return i
    return None
