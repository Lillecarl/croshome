"""Asking the terminal what colour it is, and picking a colour next to it.

Neither prompt_toolkit nor xonsh queries the terminal, so this does it by hand.
OSC 11 with `?` for an argument is the standard "what is your background
colour" question, and every terminal worth naming answers it -- xterm, foot,
kitty, WezTerm, Alacritty, iTerm2, and tmux on their behalf.

Worth the round trip because the alternatives are all wrong:

* A colour scheme's declared background describes the *theme*, not the
  terminal. xonsh's default `$XONSH_COLOR_STYLE` reports `#ffffff` while most
  people run a dark terminal, so deriving from it lands on the wrong side of
  the contrast every time.
* `$COLORFGBG` is set by a handful of terminals and nothing else.
* `reverse`, prompt_toolkit's default for `class:selected`, is exactly what the
  block cursor already looks like -- which is the complaint this module exists
  to answer.

Nothing here imports prompt_toolkit or xonsh; `integration` decides when to ask
and what to do when the terminal stays quiet.
"""

from __future__ import annotations

import io
import os
import re
import select
import sys

#: OSC 11 with `?` as the argument: "report the background colour".
BACKGROUND_QUERY = "\x1b]11;?\x07"

#: `rgb:` components are hex of any width -- terminals send 4 digits per
#: channel, the spec permits 1 to 4. Terminated by BEL or ST, neither of which
#: is matched here: the numbers are all we need, and not requiring the
#: terminator means a truncated read still parses.
_RESPONSE = re.compile(
    rb"\x1b\]11;rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})"
)

#: How long to wait for an answer. A terminal that supports the query replies
#: within a millisecond or so; one that does not never will, and this is the
#: whole cost of finding that out.
TIMEOUT = 0.05

#: Terminals that cannot answer, and would spend the timeout proving it. The
#: Linux console in particular parses OSC and discards it in silence.
_MUTE_TERMS = frozenset({"", "dumb", "linux", "cons25", "emacs"})

RGB = tuple[int, int, int]


def _scale(digits: bytes) -> int:
    """Scale a hex component of any width onto 0-255."""
    return round(int(digits, 16) * 255 / (16 ** len(digits) - 1))


def parse_background(data: bytes) -> RGB | None:
    """Pull an OSC 11 reply out of whatever the terminal sent back."""
    match = _RESPONSE.search(data)
    if match is None:
        return None
    return (
        _scale(match.group(1)),
        _scale(match.group(2)),
        _scale(match.group(3)),
    )


def query_background(timeout: float = TIMEOUT) -> RGB | None:
    """Ask the terminal for its background colour. `None` if it will not say.

    Call this *before* prompt_toolkit takes over the input -- from an rc file,
    not from inside a prompt -- because it reads the terminal directly.

    One caveat, accepted rather than solved: bytes typed during the round trip
    are read here and cannot be pushed back onto a tty, so type-ahead in the
    first few milliseconds of a shell can be swallowed. The window is the same
    one in which the shell is not yet listening anyway.
    """
    import termios
    import time
    import tty

    try:
        in_fd = sys.stdin.fileno()
        out = sys.stdout
    except (AttributeError, ValueError, io.UnsupportedOperation):
        return None

    if os.environ.get("TERM", "") in _MUTE_TERMS:
        return None
    try:
        if not (os.isatty(in_fd) and out.isatty()):
            return None
        saved = termios.tcgetattr(in_fd)
    except (OSError, ValueError, termios.error):
        return None

    data = b""
    try:
        # cbreak rather than raw: it is the minimum needed to read the reply
        # without waiting for a newline, and leaves signal handling alone.
        tty.setcbreak(in_fd, termios.TCSANOW)
        out.write(BACKGROUND_QUERY)
        out.flush()

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([in_fd], [], [], remaining)[0]:
                break
            chunk = os.read(in_fd, 64)
            if not chunk:
                break
            data += chunk
            # Stop as soon as a complete reply is in hand rather than sitting
            # out the timeout: this runs on every shell start.
            if parse_background(data) is not None and (
                data.endswith(b"\x07") or data.endswith(b"\x1b\\")
            ):
                break
    except (OSError, termios.error):
        return None
    finally:
        try:
            termios.tcsetattr(in_fd, termios.TCSANOW, saved)
        except termios.error:
            pass

    return parse_background(data)


#: How far the selection background moves, in CIE L* -- perceptual lightness,
#: 0 for black and 100 for white.
#:
#: A constant step *there* looks the same on a near-black terminal and a
#: near-white one. A constant step in sRGB channels does not, because sRGB is
#: gamma encoded: blending 14% toward black turns #ffffff into a decidedly grey
#: #dbdbdb, while blending 14% toward white barely lifts #000000 off the floor.
SHIFT_LSTAR = 9.0


def _to_linear(channel: int) -> float:
    c = channel / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _to_srgb(value: float) -> int:
    value = min(1.0, max(0.0, value))
    c = value * 12.92 if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055
    return round(c * 255)


def relative_luminance(rgb: RGB) -> float:
    """WCAG relative luminance, 0 for black and 1 for white."""
    r, g, b = (_to_linear(channel) for channel in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def lightness(rgb: RGB) -> float:
    """CIE L*: perceptual lightness, 0 for black and 100 for white."""
    y = relative_luminance(rgb)
    return 116 * y ** (1 / 3) - 16 if y > 216 / 24389 else y * 24389 / 27


def _luminance_for(lstar: float) -> float:
    return ((lstar + 16) / 116) ** 3 if lstar > 8 else lstar * 27 / 24389


def shifted(rgb: RGB, step: float = SHIFT_LSTAR) -> str:
    """A `#rrggbb` a little away from `rgb`, toward whichever end is further.

    Deliberately a small step. The selection should read as "these characters
    are picked out", not as a second cursor -- the block cursor sitting inside
    the selection is what has to stay the loudest thing on the line.

    Hue is preserved by blending toward white or black in *linear* light, where
    luminance is a straight average and the blend factor needed to land on a
    given L* can be solved for directly.
    """
    linear = [_to_linear(channel) for channel in rgb]
    y = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    lstar = lightness(rgb)

    if lstar < 50:
        target = _luminance_for(min(100.0, lstar + step))
        factor = 0.0 if y >= 1 else (target - y) / (1 - y)
        factor = min(1.0, max(0.0, factor))
        blended = [c + (1 - c) * factor for c in linear]
    else:
        target = _luminance_for(max(0.0, lstar - step))
        factor = 0.0 if y <= 0 else 1 - target / y
        factor = min(1.0, max(0.0, factor))
        blended = [c * (1 - factor) for c in linear]

    r, g, b = (_to_srgb(c) for c in blended)
    return f"#{r:02x}{g:02x}{b:02x}"
