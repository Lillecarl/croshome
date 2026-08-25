"""Helix's own test notation, so upstream's cases can be pasted in verbatim.

`#[` opens the primary selection and `]#` closes it; `#(` and `)#` do the same
for a secondary one. A `|` marks which end the cursor (the "head") is on.
`#[foo|]#` is a forward selection over "foo", `#[|foo]#` the same selection made
backwards, and `#[a|]#b#(c|)#` is two cursors with the first one primary. That is
the entire format, and it is exactly what `helix-core/src/test.rs` implements --
keeping to it means a case copied out of `helix-term/tests/` is a valid case
here.

Selections are written in document order, which is the order `Selection` keeps
them in; the primary is wherever `#[` appears rather than always first.
"""

from __future__ import annotations

from .editor import Editor, Mode
from .selection import Range, Selection

#: `(opener, closer)` for each kind, and whether it marks the primary.
_MARKERS = (("#[", "]#", True), ("#(", ")#", False))
_OPENERS = {opener: primary for opener, _, primary in _MARKERS}
_CLOSERS = {closer: primary for _, closer, primary in _MARKERS}


class AnnotationError(ValueError):
    """A `#[...]#` test string could not be parsed."""


def parse_annotated(annotated: str) -> tuple[str, Selection]:
    """`"a#[b|]#c"` -> `("abc", Selection.single(1, 2))`."""
    body: list[str] = []
    ranges: list[Range] = []
    primary_index: int | None = None
    #: `(start, is_primary, head_at_start)` while a selection is open.
    opened: tuple[int, bool, bool] | None = None
    head_at_end = False

    i = 0
    while i < len(annotated):
        pair = annotated[i : i + 2]

        if pair in _OPENERS:
            if opened is not None:
                raise AnnotationError(
                    f"a selection opens inside another in {annotated!r}"
                )
            i += 2
            head_at_start = annotated[i : i + 1] == "|"
            if head_at_start:
                i += 1
            opened = (len(body), _OPENERS[pair], head_at_start)
            head_at_end = False
            continue

        if pair in _CLOSERS:
            if opened is None:
                raise AnnotationError(f"stray {pair!r} in {annotated!r}")
            start, is_primary, head_at_start = opened
            if _CLOSERS[pair] is not is_primary:
                raise AnnotationError(f"mismatched selection markers in {annotated!r}")
            if not head_at_start and not head_at_end:
                raise AnnotationError(f"missing `|` marking the head in {annotated!r}")
            end = len(body)
            if is_primary:
                if primary_index is not None:
                    raise AnnotationError(f"more than one `#[` in {annotated!r}")
                primary_index = len(ranges)
            ranges.append(Range(end, start) if head_at_start else Range(start, end))
            opened = None
            i += 2
            # Helix's escape hatch for a cursor sitting on a line ending: the
            # newline is written inside the selection *and* again after it, and
            # the second one is dropped. Without this there is no way to write
            # that state down.
            if body and body[-1] == "\n" and annotated[i : i + 1] == "\n":
                i += 1
            continue

        char = annotated[i]
        if (
            char == "|"
            and opened is not None
            and not opened[2]
            and annotated[i + 1 : i + 3] in _CLOSERS
        ):
            head_at_end = True
            i += 1
            continue

        body.append(char)
        i += 1

    if opened is not None:
        raise AnnotationError(f"unterminated selection in {annotated!r}")
    if primary_index is None:
        raise AnnotationError(f"no primary selection `#[` in {annotated!r}")
    return "".join(body), Selection(tuple(ranges), primary_index)


def render_annotated(text: str, selection: Selection | Range) -> str:
    """The inverse of `parse_annotated`, for assertion messages that read well.

    Takes a bare `Range` too, which is what a caller holding only the primary
    -- `editor.range` -- has to hand.
    """
    if isinstance(selection, Range):
        selection = Selection.single(selection.anchor, selection.head)

    out: list[str] = []
    at = 0
    for index, rng in enumerate(selection):
        opener, closer, _ = _MARKERS[0 if index == selection.primary_index else 1]
        out.append(text[at : rng.start])
        content = rng.slice(text)
        if rng.is_empty:
            out.append(f"{opener}|{closer}")
        elif rng.head < rng.anchor:
            out.append(f"{opener}|{content}{closer}")
        else:
            out.append(f"{opener}{content}|{closer}")
        at = rng.end
    out.append(text[at:])
    return "".join(out)


def editor_from(annotated: str, mode: Mode = Mode.NORMAL) -> Editor:
    text, selection = parse_annotated(annotated)
    return Editor(text=text, selection=selection, mode=mode)


def feed(annotated: str, keys: str, mode: Mode = Mode.NORMAL) -> str:
    """Run `keys` against an annotated document and render the result.

    The single call every keymap test is written in terms of::

        assert feed("#[f|]#oo", "wd") == "#[|]#"
    """
    editor = editor_from(annotated, mode)
    editor.feed_keys(keys)
    return render_annotated(editor.text, editor.selection)
