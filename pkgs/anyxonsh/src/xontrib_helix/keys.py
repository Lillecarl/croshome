"""Canonical key tokens.

The same notation Helix uses for macros and for its own integration tests:
a bare character, or an angle-bracketed name (`<esc>`, `<ret>`, `<A-;>`,
`<C-w>`). Adopting it wholesale means a Helix test case can be pasted into
`tests/` unchanged, which is the point -- upstream's suite is the only
trustworthy oracle for what these keys are supposed to do.
"""

from __future__ import annotations

ESC = "<esc>"
RET = "<ret>"
TAB = "<tab>"
BACKSPACE = "<backspace>"

#: Helix spells a few characters by name so they survive being written inside a
#: key sequence. Everything else is its own literal.
_NAMED_CHARS = {
    "space": " ",
    "minus": "-",
    "lt": "<",
    "gt": ">",
    "percent": "%",
    "semicolon": ";",
    "plus": "+",
    "period": ".",
}

#: Recognised bare key names. Anything else in angle brackets is rejected rather
#: than silently treated as a literal, so a typo in a test fails loudly.
KEY_NAMES = frozenset(
    {
        "esc",
        "ret",
        "tab",
        "backspace",
        "del",
        "left",
        "right",
        "up",
        "down",
        "home",
        "end",
        "pageup",
        "pagedown",
        "insert",
    }
)


class KeyParseError(ValueError):
    """A key sequence could not be parsed."""


def parse_keys(sequence: str) -> list[str]:
    """Split a Helix macro string into canonical tokens.

    >>> parse_keys("wd<esc>")
    ['w', 'd', '<esc>']
    >>> parse_keys("<A-;>")
    ['<A-;>']
    """
    tokens: list[str] = []
    i = 0
    while i < len(sequence):
        ch = sequence[i]
        if ch != "<":
            tokens.append(ch)
            i += 1
            continue
        close = sequence.find(">", i + 1)
        if close == -1:
            raise KeyParseError(
                f"unterminated `<` at offset {i} in {sequence!r} "
                "-- a literal `<` is written `<lt>`"
            )
        body = sequence[i + 1 : close]
        tokens.append(_normalise(body, sequence))
        i = close + 1
    return tokens


def _normalise(body: str, sequence: str) -> str:
    lowered = body.lower()
    if lowered in _NAMED_CHARS:
        return _NAMED_CHARS[lowered]
    if lowered in KEY_NAMES:
        return f"<{lowered}>"
    if len(body) > 2 and body[1] == "-" and body[0] in "ACS":
        modifier, rest = body[0], body[2:]
        # `<A-space>` and friends: resolve the inner name first so the modifier
        # is always applied to a canonical key.
        inner = _NAMED_CHARS.get(rest.lower())
        if inner is None and rest.lower() in KEY_NAMES:
            inner = f"<{rest.lower()}>"
        return f"<{modifier}-{inner if inner is not None else rest}>"
    raise KeyParseError(f"unknown key <{body}> in {sequence!r}")


def is_alt(token: str) -> bool:
    return token.startswith("<A-") and token.endswith(">")


def alt_key(token: str) -> str:
    """The key an Alt token modifies: `<A-;>` -> `;`."""
    return token[3:-1]


def is_printable(token: str) -> bool:
    """True for tokens that insert a character in insert mode."""
    return len(token) == 1 and (token.isprintable() or token == "\t")
