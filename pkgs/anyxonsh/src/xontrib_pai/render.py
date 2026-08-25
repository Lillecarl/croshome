"""Turning what the model wrote into something a terminal reads well.

Models write Markdown whether or not anyone asked them to. Printed raw at a
shell prompt that means asterisks around words that were meant to be bold,
backticks around commands, and ``` fences bracketing the one part of the answer
you actually wanted to paste. None of it is wrong; all of it is furniture that
belongs to a renderer that was never there.

What is handled, and the reason each stops where it does:

* **Bold** and `inline code`, which is the whole of the inline syntax taken
  seriously here. Not `*italic*` and not `_underscores_`: this is a shell.
  `*.txt` and `*.md` on one line would turn the space between two globs into an
  italic run, and `snake_case_names` are two underscores looking for trouble.
  The false positives cost more than the italics are worth.
* Fenced code blocks, whose fences are removed and whose contents are then left
  exactly alone -- not wrapped, not indented, not coloured. A block of code in
  an answer is usually a command about to be pasted somewhere, and every one of
  those would damage it.
* Headings and block quotes, stripped of their markers and styled instead.
* Wrapping, of prose only, to the terminal's own width, with list items
  indented under their marker rather than flush left on the second line.

Colour goes on only when stderr is a terminal, so an answer piped somewhere
arrives as text. `strip` is the same renderer with the styling turned off, and
is what the tests read.
"""

from __future__ import annotations

import re
import shutil
import sys

_BOLD = "\x1b[1m"
_DIM = "\x1b[2m"
_CODE = "\x1b[36m"
_RESET = "\x1b[0m"

#: Below this there is no useful wrapping to do, and a terminal reporting
#: something absurd (or nothing at all) should not produce one word per line.
MIN_WIDTH = 30

#: Inline spans, tried in this order so that `**` inside backticks stays inside
#: backticks. Both require the content to begin and end with a non-space, which
#: is what keeps `2 * 3 * 4` from being a bold `3`.
_INLINE = re.compile(
    r"(?P<fence>`+)(?P<code>.+?)(?P=fence)"
    r"|\*\*(?P<bold>\S(?:.*?\S)?)\*\*",
    re.DOTALL,
)

_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")
#: `- item`, `* item`, `1. item`. The indent is kept so nested lists stay nested.
_BULLET = re.compile(r"^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$")


def width() -> int:
    """How wide to wrap prose."""
    return max(MIN_WIDTH, shutil.get_terminal_size().columns)


def colour() -> bool:
    """Style only where styling will render as style."""
    try:
        return sys.stderr.isatty()
    except (AttributeError, ValueError):
        return False


#: What each kind of span turns into when there is a terminal to colour.
_STYLE = {"code": _CODE, "bold": _BOLD, "": ""}


def _segments(line: str) -> list[tuple[str, str]]:
    """One line as `(text, kind)` pairs, with the Markdown markers removed.

    The *kind* rather than the escape sequence, because it decides more than
    colour: a code span is also the thing that must not be wrapped through, and
    that has to stay true down a pipe where nothing is coloured at all.
    """
    out: list[tuple[str, str]] = []
    at = 0
    for match in _INLINE.finditer(line):
        if match.start() > at:
            out.append((line[at : match.start()], ""))
        if match.group("code") is not None:
            out.append((match.group("code"), "code"))
        else:
            out.append((match.group("bold"), "bold"))
        at = match.end()
    if at < len(line):
        out.append((line[at:], ""))
    return out


_GAP = re.compile(r"(\s+)")


def _words(segments: list[tuple[str, str]]) -> list[tuple[str, str, bool]]:
    """`(word, kind, space_before)` triples: the places a line may be broken.

    The third field is why this is not simply `str.split`. `**matters**:` comes
    out of `_segments` as a bold run followed by a colon, and rejoining on
    spaces alone would put one between them -- turning every emphasised word
    before a punctuation mark into `matters :`.

    An inline-code span is one word however many spaces are in it. That is the
    point of the exercise: `git log --oneline -20` is a thing to be pasted, and
    a wrap through the middle of it is a wrap through the middle of a command.
    """
    out: list[tuple[str, str, bool]] = []
    gap = False
    for text, kind in segments:
        if kind == "code":
            out.append((text, kind, gap and bool(out)))
            gap = False
            continue
        for part in _GAP.split(text):
            if not part:
                continue
            if part.isspace():
                gap = True
                continue
            out.append((part, kind, gap and bool(out)))
            gap = False
    return out


def _wrap(segments: list[tuple[str, str]], limit: int, styled: bool) -> list[str]:
    """Lay `segments` out in lines of no more than `limit` visible columns.

    Styling is applied here rather than before, because the escape sequences are
    zero columns wide and counting them would wrap short.
    """
    lines: list[str] = []
    current: list[str] = []
    used = 0
    for word, kind, space in _words(segments):
        width_here = len(word) + (1 if space and current else 0)
        if current and used + width_here > limit:
            lines.append("".join(current))
            current, used, space = [], 0, False
            width_here = len(word)
        if space and current:
            current.append(" ")
        style = _STYLE[kind] if styled else ""
        current.append(f"{style}{word}{_RESET}" if style else word)
        used += width_here
    if current:
        lines.append("".join(current))
    return lines or [""]


def _show(marker: str, styled: bool) -> str:
    """A line's marker, dimmed where it is furniture rather than content."""
    if not styled or not marker.strip():
        return marker
    return f"{_DIM}{marker}{_RESET}"


def render(text: str, *, limit: int | None = None, styled: bool | None = None) -> str:
    """What the model wrote, laid out for a terminal.

    Args:
        limit: columns to wrap prose at. Defaults to the terminal's width.
        styled: whether to emit colour. Defaults to "stderr is a terminal".
    """
    if limit is None:
        limit = width()
    if styled is None:
        styled = colour()

    out: list[str] = []
    fenced = False
    for line in text.replace("\r\n", "\n").expandtabs(4).split("\n"):
        if _FENCE.match(line):
            # The fence itself is furniture, and so is whatever language was
            # written after it. Both go; what was between them stays as typed.
            fenced = not fenced
            continue
        if fenced:
            out.append(line)
            continue

        if not line.strip():
            out.append("")
            continue

        # `marker` goes in front of the first line and `hang` in front of every
        # later one. They are the same width by construction, so one number
        # takes them both off the wrapping limit.
        marker = hang = ""
        body = line
        quoted = _QUOTE.match(line)
        if quoted:
            marker = hang = "| "
            body = quoted.group(1)

        heading = _HEADING.match(body)
        if heading:
            # The whole line goes bold, so its inline spans are laid out
            # unstyled: a reset in the middle would end the bold early.
            for index, text in enumerate(
                _wrap(_segments(heading.group(2)), limit - len(marker), False)
            ):
                line = _show(marker if index == 0 else hang, styled) + text
                out.append(f"{_BOLD}{line}{_RESET}" if styled else line)
            continue

        bullet = _BULLET.match(body)
        if bullet:
            indent, point, body = bullet.groups()
            marker += f"{indent}{point} "
            hang += " " * len(f"{indent}{point} ")

        for index, text in enumerate(
            _wrap(_segments(body), limit - len(marker), styled)
        ):
            out.append(_show(marker if index == 0 else hang, styled) + text)

    # Models end an answer with a newline about half the time, and a `write`
    # that adds its own would leave a blank line at a prompt every other turn.
    return "\n".join(out).strip("\n")


def strip(text: str, *, limit: int | None = None) -> str:
    """`render` with the colour off. What a pipe gets, and what tests read."""
    return render(text, limit=limit, styled=False)
