"""The `Range` and `Selection` types, ported from helix-core/src/selection.rs.

This is the whole reason Helix feels different from Vim, so it is worth being
precise about. A Helix selection is `(anchor, head)`, both *gap indices* --
positions between characters, like prompt_toolkit's `cursor_position`. What
looks like a plain cursor sitting on character 0 is really `Range(0, 1)`: a
selection one character wide. That is why `d` deletes a character with no
motion, and why every motion in Helix produces a selection rather than a point.

`head` may be less than `anchor`, which is how a selection remembers the
direction it was made in -- `Alt-;` flips it and `Alt-:` forces it forward.

A document has a `Selection`: one or more ranges, one of them primary. Every
command applies to all of them, which is what makes `s` (select every match
inside the selection) followed by `c` (change) a single edit at ten places at
once. The primary is the one the terminal's own cursor is drawn at and the one
`,` keeps; the rest are painted by `integration._HelixSelectionProcessor`,
because a terminal has exactly one cursor and prompt_toolkit draws it.

Grapheme clusters
-----------------
Helix moves by grapheme cluster; this port moves by code point. For a shell
command line that difference only shows up on emoji with modifiers and on
combining marks, where the block cursor will step through the parts. Both
boundary helpers are funnelled through `next_grapheme`/`prev_grapheme` below, so
a real implementation is a two-function change rather than a rewrite.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from enum import Enum


class Direction(Enum):
    FORWARD = "forward"
    BACKWARD = "backward"


def next_grapheme(text: str, pos: int) -> int:
    return min(pos + 1, len(text))


def prev_grapheme(text: str, pos: int) -> int:
    return max(pos - 1, 0)


def nth_next_grapheme(text: str, pos: int, n: int) -> int:
    return min(pos + n, len(text))


def nth_prev_grapheme(text: str, pos: int, n: int) -> int:
    return max(pos - n, 0)


@dataclass(frozen=True)
class Range:
    anchor: int
    head: int

    @classmethod
    def point(cls, pos: int) -> "Range":
        return cls(pos, pos)

    @property
    def start(self) -> int:
        """Helix calls this `from`, which is a Python keyword."""
        return min(self.anchor, self.head)

    @property
    def end(self) -> int:
        """Helix calls this `to`. Exclusive: `text[start:end]` is the content."""
        return max(self.anchor, self.head)

    def __len__(self) -> int:
        return self.end - self.start

    @property
    def is_empty(self) -> bool:
        return self.anchor == self.head

    @property
    def direction(self) -> Direction:
        return Direction.BACKWARD if self.head < self.anchor else Direction.FORWARD

    def flip(self) -> "Range":
        return Range(self.head, self.anchor)

    def with_direction(self, direction: Direction) -> "Range":
        return self if self.direction is direction else self.flip()

    def slice(self, text: str) -> str:
        return text[self.start : self.end]

    def overlaps(self, other: "Range") -> bool:
        """Do these two share any character, or start in the same place?

        The `start ==` term is what makes two *cursors* on the same position
        count as overlapping even though neither contains anything -- without
        it `C` on the last line would leave a second cursor stacked invisibly
        on the first.
        """
        return self.start == other.start or (
            self.end > other.start and other.end > self.start
        )

    def merge(self, other: "Range") -> "Range":
        """The smallest range covering both, keeping a shared direction.

        Two backwards ranges merge into a backwards one; anything else comes
        out forwards. Helix's rule, and it matters because the merged range
        inherits which end the block cursor sits on.
        """
        if self.anchor > self.head and other.anchor > other.head:
            return Range(max(self.anchor, other.anchor), min(self.head, other.head))
        return Range(min(self.start, other.start), max(self.end, other.end))

    def min_width_1(self, text: str) -> "Range":
        """A zero-width range is not representable as a block cursor."""
        if self.anchor == self.head:
            return Range(self.anchor, next_grapheme(text, self.head))
        return self

    def cursor(self, text: str) -> int:
        """Left edge of the block cursor -- the index of the character under it."""
        if self.head > self.anchor:
            return prev_grapheme(text, self.head)
        return self.head

    def put_cursor(self, text: str, char_idx: int, extend: bool) -> "Range":
        """Move the block cursor to `char_idx`, extending the range or not.

        The anchor nudges by one when the range changes direction, so that both
        ends keep behaving like one-wide blocks. Without that, reversing over
        the anchor loses a character.
        """
        if not extend:
            return Range.point(char_idx)

        if self.head >= self.anchor and char_idx < self.anchor:
            anchor = next_grapheme(text, self.anchor)
        elif self.head < self.anchor and char_idx >= self.anchor:
            anchor = prev_grapheme(text, self.anchor)
        else:
            anchor = self.anchor

        if anchor <= char_idx:
            return Range(anchor, next_grapheme(text, char_idx))
        return Range(anchor, char_idx)

    def line_range(self, text: str) -> tuple[int, int]:
        """Inclusive range of line numbers the selection touches."""
        start = self.start
        end = self.end if self.is_empty else max(prev_grapheme(text, self.end), start)
        return char_to_line(text, start), char_to_line(text, end)


@dataclass(frozen=True)
class Selection:
    """One or more `Range`s, one of them primary. Never empty.

    Kept sorted and non-overlapping by `normalize`, which every constructor and
    every transform runs. That invariant is what the rest of the editor is
    written against: multi-range edits are applied right to left and would
    corrupt the text if two ranges could overlap, and the renderer would paint
    the same character twice.

    Frozen, like `Range`. A command builds a new `Selection` and assigns it,
    rather than mutating one that something else may still be looking at --
    `_snapshot` keeps them in the undo stack, and a mutable one there would
    quietly rewrite history.
    """

    ranges: tuple[Range, ...] = (Range(0, 0),)
    primary_index: int = 0

    # ------------------------------------------------------------ building --

    @classmethod
    def single(cls, anchor: int, head: int) -> "Selection":
        return cls((Range(anchor, head),), 0)

    @classmethod
    def point(cls, pos: int) -> "Selection":
        return cls.single(pos, pos)

    @classmethod
    def of(cls, ranges: Iterable[Range], primary_index: int = 0) -> "Selection":
        """From an arbitrary iterable, normalized. Empty input is a programming
        error everywhere it could arise, so it is not quietly repaired."""
        collected = tuple(ranges)
        if not collected:
            raise ValueError("a Selection needs at least one range")
        return cls(collected, min(primary_index, len(collected) - 1)).normalize()

    # ------------------------------------------------------------- reading --

    @property
    def primary(self) -> Range:
        return self.ranges[self.primary_index]

    def __len__(self) -> int:
        return len(self.ranges)

    def __iter__(self) -> Iterator[Range]:
        return iter(self.ranges)

    def __getitem__(self, index: int) -> Range:
        return self.ranges[index]

    @property
    def multi(self) -> bool:
        return len(self.ranges) > 1

    def fragments(self, text: str) -> list[str]:
        return [rng.slice(text) for rng in self.ranges]

    # ---------------------------------------------------------- transforms --

    def normalize(self) -> "Selection":
        """Sort by start and merge anything overlapping, keeping the primary.

        The primary is followed by *value* rather than by index, because the
        sort moves it and a merge replaces it with something wider. Helix does
        the same, for the same reason: after `C` the new cursor below is what
        you want to be typing at, and after two ranges collide the survivor has
        to inherit whichever of them was primary.
        """
        if len(self.ranges) < 2:
            return self
        if self._settled():
            return self
        primary = self.ranges[self.primary_index]
        merged: list[Range] = []
        for rng in sorted(self.ranges, key=lambda r: (r.start, r.end)):
            if merged and merged[-1].overlaps(rng):
                combined = rng.merge(merged[-1])
                if merged[-1] == primary or rng == primary:
                    primary = combined
                merged[-1] = combined
            else:
                merged.append(rng)
        try:
            index = merged.index(primary)
        except ValueError:  # unreachable: every merge that ate it reassigned it
            index = 0
        return Selection(tuple(merged), index)

    def _settled(self) -> bool:
        """Are the ranges already sorted and disjoint, so `normalize` is a no-op?

        Almost always, and that is the point. A motion moves every range the
        same way and an edit shifts them all by what came before, so order and
        separation survive both; the sort and the merge are then pure cost. With
        a cursor on every word of a long line they are the cost -- `s` on a
        thousand words meant a thousand-element sort per keystroke, twice.

        Adjacent pairs are enough to check. Sorted by start, a range can only
        overlap its neighbour: if `a.end <= b.start <= c.start` then `a` cannot
        reach `c` either.

        `start` and `end` are spelled out rather than read off the properties,
        because this runs once per range per keystroke and each of those is a
        `min` behind an attribute lookup.
        """
        previous = self.ranges[0]
        low = min(previous.anchor, previous.head)
        high = max(previous.anchor, previous.head)
        for rng in self.ranges[1:]:
            start = min(rng.anchor, rng.head)
            end = max(rng.anchor, rng.head)
            if start < low or (start == low and end < high):
                return False  # out of order
            if start == low or high > start:
                return False  # overlapping, by `Range.overlaps`
            low, high = start, end
        return True

    def transform(self, fn: Callable[[Range], Range]) -> "Selection":
        """Map every range through `fn`. The workhorse: every motion is this.

        `fn` is applied positionally and `normalize` then follows the primary
        by value, so the primary comes out pointing at whatever its own range
        turned into -- including when the transform made it collide with a
        neighbour and the two became one.
        """
        return Selection(
            tuple(fn(rng) for rng in self.ranges), self.primary_index
        ).normalize()

    def transform_iter(self, fn: Callable[[Range], Iterable[Range]]) -> "Selection":
        """Map every range to zero or more ranges. `s`, `S` and `Alt-s`.

        A range that yields nothing is dropped. If *everything* is dropped the
        selection is left alone, because a selection cannot be empty and a
        regex that matched nothing should not silently move the cursor.

        The primary follows: it becomes the first range the old primary
        produced. Helix leaves it at 0 here; keeping it means `s` on a
        multi-line selection does not jump the terminal cursor to the top.
        """
        produced: list[Range] = []
        primary_at = 0
        for i, rng in enumerate(self.ranges):
            made = list(fn(rng))
            if i == self.primary_index and made:
                primary_at = len(produced)
            produced.extend(made)
        if not produced:
            return self
        return Selection(
            tuple(produced), min(primary_at, len(produced) - 1)
        ).normalize()

    def set_primary(self, index: int) -> "Selection":
        return Selection(self.ranges, index % len(self.ranges))

    def replace_primary(self, rng: Range) -> "Selection":
        """Swap the primary range for `rng`, leaving the others alone."""
        ranges = list(self.ranges)
        ranges[self.primary_index] = rng
        return Selection(tuple(ranges), self.primary_index).normalize()

    def into_single(self) -> "Selection":
        """`,` -- keep only the primary."""
        if len(self.ranges) == 1:
            return self
        return Selection((self.primary,), 0)

    def push(self, rng: Range) -> "Selection":
        """Add a range and make it primary."""
        return Selection.of((*self.ranges, rng), len(self.ranges))

    def remove(self, index: int) -> "Selection":
        """Drop one range. Refuses to empty the selection."""
        if len(self.ranges) == 1:
            return self
        ranges = list(self.ranges)
        del ranges[index]
        primary = self.primary_index
        if index < primary or primary == len(ranges):
            primary -= 1
        return Selection(tuple(ranges), max(primary, 0))

    def merge_ranges(self) -> "Selection":
        """`Alt--` -- one range spanning from the first to the last."""
        return Selection((self.ranges[0].merge(self.ranges[-1]),), 0)

    def merge_consecutive(self) -> "Selection":
        """`Alt-_` -- join only the ranges that touch end-to-start."""
        if len(self.ranges) < 2:
            return self
        primary = self.primary
        merged: list[Range] = []
        for rng in self.ranges:
            if merged and merged[-1].end == rng.start:
                combined = rng.merge(merged[-1])
                if merged[-1] == primary or rng == primary:
                    primary = combined
                merged[-1] = combined
            else:
                merged.append(rng)
        try:
            index = merged.index(primary)
        except ValueError:
            index = 0
        return Selection(tuple(merged), index)

    def cursors(self, text: str) -> "Selection":
        """`;` -- collapse every range onto its own block cursor."""
        return self.transform(lambda rng: Range.point(rng.cursor(text)))

    def ensure_invariants(self, text: str) -> "Selection":
        """Clamp to the text and widen every bare point to one character."""
        n = len(text)

        def fix(rng: Range) -> Range:
            return Range(min(rng.anchor, n), min(rng.head, n)).min_width_1(text)

        return self.transform(fix)

    def clamped(self, text: str) -> "Selection":
        n = len(text)
        return self.transform(lambda rng: Range(min(rng.anchor, n), min(rng.head, n)))


def char_to_line(text: str, pos: int) -> int:
    return text.count("\n", 0, min(pos, len(text)))


def line_to_char(text: str, line: int) -> int:
    """Index of the first character of `line`, clamped to the last line."""
    if line <= 0:
        return 0
    pos = 0
    for _ in range(line):
        nxt = text.find("\n", pos)
        if nxt == -1:
            return pos
        pos = nxt + 1
    return pos


def line_count(text: str) -> int:
    return text.count("\n") + 1


def line_bounds(text: str, line: int) -> tuple[int, int]:
    """`(start, end)` of `line`, with `end` *before* the trailing newline."""
    start = line_to_char(text, line)
    nxt = text.find("\n", start)
    return start, len(text) if nxt == -1 else nxt
