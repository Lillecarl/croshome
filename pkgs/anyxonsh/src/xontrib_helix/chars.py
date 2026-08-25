"""Character classification, ported from helix-core/src/chars.rs.

Word motions are the part of Helix people notice most when it is subtly wrong,
and every one of them is defined in terms of *category transitions* rather than
regexes. So the categories have to match upstream exactly, including the
distinction between "whitespace" and "end of line" -- `w` stops at a newline,
but a space it merely passes through.
"""

from __future__ import annotations

import unicodedata
from enum import Enum

#: Everything Helix's `LineEnding::from_char` accepts, spelled with escapes so
#: the two invisible ones stay visible in a diff. A prompt_toolkit buffer only
#: ever contains "\n", but this classification is shared with the textobject and
#: surround code, which a user may point at pasted text.
LINE_ENDINGS = frozenset(
    [
        "\n",  # LF
        "\r",  # CR
        "\x0b",  # VT
        "\x0c",  # FF
        "\x85",  # NEL
        " ",  # LS
        " ",  # PS
    ]
)

#: Unicode general categories Helix counts as punctuation. Note that this pulls
#: in the symbol categories too -- `$`, `+` and `^` are punctuation for the
#: purposes of a word motion, which is what makes `w` useful in a shell.
_PUNCTUATION_CATEGORIES = frozenset(
    {"Po", "Ps", "Pe", "Pi", "Pf", "Pc", "Pd", "Sm", "Sc", "Sk"}
)


class CharCategory(Enum):
    WHITESPACE = "whitespace"
    EOL = "eol"
    WORD = "word"
    PUNCTUATION = "punctuation"
    UNKNOWN = "unknown"


def char_is_line_ending(ch: str) -> bool:
    return ch in LINE_ENDINGS


def char_is_word(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


def char_is_punctuation(ch: str) -> bool:
    return unicodedata.category(ch) in _PUNCTUATION_CATEGORIES


def categorize_char(ch: str) -> CharCategory:
    if char_is_line_ending(ch):
        return CharCategory.EOL
    if ch.isspace():
        return CharCategory.WHITESPACE
    if char_is_word(ch):
        return CharCategory.WORD
    if char_is_punctuation(ch):
        return CharCategory.PUNCTUATION
    return CharCategory.UNKNOWN


def is_word_boundary(a: str, b: str) -> bool:
    return categorize_char(a) is not categorize_char(b)


def is_long_word_boundary(a: str, b: str) -> bool:
    """Boundary for `W`/`B`/`E`, where punctuation does not split a word."""
    ca, cb = categorize_char(a), categorize_char(b)
    if (ca is CharCategory.WORD and cb is CharCategory.PUNCTUATION) or (
        ca is CharCategory.PUNCTUATION and cb is CharCategory.WORD
    ):
        return False
    return ca is not cb
