"""Turning what a command wrote into what a person would have seen.

The model's commands run on a pty of their own -- xonsh does that whenever it
captures, and it is the right thing: `isatty()` answers True, so programs
behave the way they behave for the user rather than the way they behave in a
pipe. The cost is that the bytes coming back are meant for a *screen*. Colour,
carriage returns that rewrite a line, erase-to-end-of-line, the private mode
switches a full-screen program uses on its way in and out. A terminal resolves
all of that into a picture. A file handed to a language model does not.

What that looks like from the model's side, before this:

    \\x1b[?1h\\x1b=\\r* \\x1b[33mc7b39b5\\x1b[m\\x1b[33m (\\x1b[m\\x1b[1;36mHEAD ...

-- and a progress bar arrives as every frame it ever drew, one after another,
which is both unreadable and expensive: the context window pays for each one.

`pyte`, a VT100 emulator, was the obvious candidate and is not what this does.
Measured on 680 KB of ordinary test output -- coloured, one line per test --
against the strip-and-collapse below:

    pyte.HistoryScreen           3429 ms     0.20 MB/s
    pyte.Screen (no scrollback)  1072 ms     0.63 MB/s   keeps only 24 lines
    this module                     7 ms    98.38 MB/s

Three and a half seconds of a worker thread for one test run, and the drain
thread doing it is the same one feeding the user's live view. `pyte.Screen` is
faster and useless -- a screen is twenty-four lines and a tool result is not.

What the emulator gets right and this does not is absolute cursor motion:
`\\x1b[1A` moving up to overwrite an earlier line. Outside full-screen programs
-- which are their own problem, not this one -- that is rare, and the trade is
five hundred times the throughput. If a case turns up where it matters, the
answer is to emulate *that command*, not every command.

So: drop the escape sequences, and honour `\\r` because that one is not
decoration. It is a program saying "this line again, from the start", which is
how every progress bar in the world is drawn, and taking it literally is the
difference between one line and five hundred.
"""

from __future__ import annotations

import re

#: Everything a terminal reads and does not show. In order: CSI (`\x1b[`, the
#: colours and the cursor moves), the string-argument sequences OSC/DCS/PM/APC
#: which run until a bell or a string terminator -- window titles arrive this
#: way, several times a second, from xonsh itself -- and the two- and
#: three-character escapes, `\x1b=` and friends, that a pager uses to switch
#: keypad modes on its way in and out.
_ESCAPES = re.compile(
    r"""
    \x1b\[ [0-?]* [ -/]* [@-~]              # CSI ... final byte
    | \x1b [\]P^_] .*? (?: \x07 | \x1b\\ )  # OSC/DCS/PM/APC ... terminator
    | \x1b [ -/]* [0-~]                     # everything else beginning ESC
    """,
    re.VERBOSE | re.DOTALL,
)

#: The other control characters worth losing. Not `\t`, which is real layout,
#: and not `\r` or `\n`, which are handled properly below. `\x08` is a
#: backspace, which programs use to rub out a character they have just drawn;
#: leaving it in makes a line say the opposite of what it shows.
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def legible(text: str) -> str:
    """What `text` would have looked like on the screen it was written for.

    Line by line, because that is the unit `\\r` works in and the unit the
    result is read in. Everything after the last carriage return on a line is
    what a terminal would be showing when the line ended -- the finished
    progress bar, not the two hundred frames before it.
    """
    lines = _ESCAPES.sub("", text).replace("\r\n", "\n").split("\n")
    return "\n".join(_CONTROL.sub("", line.rpartition("\r")[2]) for line in lines)
