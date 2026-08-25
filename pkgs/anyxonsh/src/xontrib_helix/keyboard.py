"""Asking the terminal whether it speaks the Kitty keyboard protocol.

Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/

The shape of this file copies `terminal.py` next door on purpose: write one
query, wait a few milliseconds for an answer, remember. The question here is
`CSI ? u` -- "which keyboard-enhancement flags are in effect?" -- and every
compliant terminal answers `CSI ? <flags>u` within the round trip of writing
it. A terminal that does not speak the protocol stays silent, and silence is
the answer.

Detection alone changes nothing. What it buys is permission to *push* flags,
and the one this module pushes is bit 1, "disambiguate escape codes": legacy
keys keep their byte-for-byte encodings -- Enter stays `\\r`, letters stay
letters -- while combinations that are otherwise unrepresentable start
arriving as distinct `CSI u` sequences instead of being mangled into
barely-distinguishable escape soup. Shift+Enter becomes `CSI 13;2u`, which
prompt_toolkit cannot parse but our key registry can bind by hand, and that is
how a shell gets real multiline input without backslash continuations.

Nothing here imports prompt_toolkit or xonsh. Run the probe before prompt_toolkit
takes over the input -- from an rc file -- for the same reason `terminal.py`
says so there: it reads the tty directly, and type-ahead typed during the few
milliseconds of probing is swallowed. It is the same window in which the shell
is not listening yet anyway.
"""

from __future__ import annotations


import os
import re
import select
import sys

#: `CSI ? u`: report the currently active enhancement flags.
QUERY = "\x1b[?u"

#: `CSI < u`: pop the most recently pushed set. Pushed flags are a stack, so
#: what we push we pop exactly once.
POP = "\x1b[<u"

_RESPONSE = re.compile(rb"\x1b\[\?(\d+)u")

#: How long to wait for an answer -- same arithmetic as the background query:
#: a compliant terminal replies immediately, a non-compliant one never will.
TIMEOUT = 0.05

#: Terminals that would spend the timeout proving they cannot answer. Same
#: list, same reasoning as `terminal.py`.
_MUTE_TERMS = frozenset({"", "dumb", "linux", "cons25", "emacs"})

#: Bit 1: disambiguate escape codes. The only flag pushed today.
DISAMBIGUATE = 1


def parse_reply(data: bytes) -> int | None:
    """Pull a flags value out of raw terminal input, or say there was none."""
    match = _RESPONSE.search(data)
    if match is None:
        return None
    return int(match.group(1))


def query(timeout: float = TIMEOUT) -> int | None:
    """Ask the terminal which keyboard flags it has in effect.

    Returns the flags integer, or `None` when the terminal does not answer --
    which is the definition of "does not support the protocol" for everything
    downstream cares about.

    Speaks through `/dev/tty` rather than stdin/stdout, learned the hard way:
    xonsh may have replaced either by the time an rc file runs, and the
    controlling terminal is the one device whose answer we actually want.
    """
    import termios
    import time
    import tty

    if os.environ.get("TERM", "") in _MUTE_TERMS:
        return None
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        saved = termios.tcgetattr(tty_fd)
    except (OSError, ValueError, termios.error):
        return None

    data = b""
    try:
        # cbreak rather than raw, for the same reason as the background query.
        tty.setcbreak(tty_fd, termios.TCSANOW)
        os.write(tty_fd, QUERY.encode())

        # An env override exists for tests: a scripted terminal answers slower
        # than a real one by orders of magnitude.
        timeout = float(os.environ.get("ANYXONSH_KEYBOARD_TIMEOUT", timeout))
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([tty_fd], [], [], remaining)[0]:
                break
            chunk = os.read(tty_fd, 64)
            if not chunk:
                break
            data += chunk
            if parse_reply(data) is not None:
                break  # a complete reply needs no terminator beyond its `u`
    except (OSError, termios.error):
        return None
    finally:
        try:
            termios.tcsetattr(tty_fd, termios.TCSANOW, saved)
            os.close(tty_fd)
        except (termios.error, OSError):
            pass

    return parse_reply(data)


def push(flags: int) -> bool:
    """Put `flags` onto the terminal's enhancement stack. True when written."""
    try:
        out = open("/dev/tty", "w")
    except OSError:
        return False
    with out:
        out.write(f"\x1b[>{flags}u")
        out.flush()
    return True


def pop() -> None:
    """Undo the most recent `push`. Registered with `atexit` by `enable`."""
    try:
        out = open("/dev/tty", "w")
    except OSError:
        return
    with out:
        out.write(POP)
        out.flush()


def enable() -> bool:
    """Probe, and on success push DISAMBIGUATE for the life of this process.

    Cached: the terminal will not change its mind mid-session. The answer is
    also published as `$ANYXONSH_KEYBOARD` ("kitty" or "") so anything after
    this -- key bindings, future features -- asks the environment rather than
    re-probing the tty.
    """
    global _enabled
    if _enabled is not None:
        return _enabled

    from xonsh.built_ins import XSH

    flags = query()
    _enabled = False
    if flags is not None and push(DISAMBIGUATE):
        import atexit

        atexit.register(pop)
        _enabled = True
    if XSH.env is not None:
        XSH.env["ANYXONSH_KEYBOARD"] = "kitty" if _enabled else ""
    return _enabled


_enabled: bool | None = None
