"""Drive a real anyxonsh in a scratch tmux session via libtmux.

Usage:

    nix run .#pkgs.anyxonsh-tests   # or: python3 tests/completions.py <binary>

Every case sends real keys and asserts on what tmux captured back, so what
is checked is what a person would see -- not internals. A case fails on a
missing screen expectation or on any traceback text appearing anywhere in
the scrollback.

tmux knows nothing about the Kitty keyboard protocol or its ANSI extensions,
so those flows are invisible here and stay covered by pty-based checks.
"""

import os
import re
import shutil
import sys
import time

import libtmux

SESSION = "anyxonsh-test"
CRASH = ("Traceback", "Press ENTER to continue", "Unhandled exception")
TRACE = bool(os.environ.get("TRACE"))
#: The binary under test, recorded by main(); the persistence case reboots
#: with it to prove history survives a process boundary.
BINARY = [None]
#: Terminal noise: SGR colour runs and OSC titles (whose payload is the
#: cwd -- real text that would otherwise satisfy word assertions).
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07")

#: One server for the whole run; sessions come and go beneath it.
SERVER: libtmux.Server | None = None


def session() -> libtmux.Session:
    for existing in SERVER.sessions:
        if existing.session_name == SESSION:
            return existing
    raise RuntimeError(f"tmux session {SESSION!r} is gone")


def pane():
    return session().active_window.active_pane


def boot(binary):
    global SERVER
    SERVER = SERVER or libtmux.Server()
    for existing in list(SERVER.sessions):
        if existing.session_name == SESSION:
            existing.kill()
    SERVER.new_session(session_name=SESSION, x=180, y=40,
                       window_command=binary)
    end = time.time() + 30
    while time.time() < end:
        if "@\n" in capture():
            break
        time.sleep(0.3)
    time.sleep(1.0)


def send(*keys, wait=0.6):
    """Type each argument as tmux would read it: key names (`C-r`, `Escape`,
    `Enter`, `Down`) arrive as keys, anything else arrives as typed text."""
    for k in keys:
        pane().send_keys(k, enter=False)
        time.sleep(0.08)
        if TRACE:
            print(f"[trace] after {k!r}: {screen()}")
    time.sleep(wait)
    if TRACE:
        print(f"[trace] settle({wait}): {screen()}")


def capture(scrollback=0):
    args = ["capture-pane", "-p"]
    if scrollback:
        args += ["-S", str(-scrollback)]
    return ANSI.sub("", "\n".join(pane().cmd(*args).stdout))


def screen(scrollback=0):
    # Collapse runs of blanks so redraw residue cannot satisfy a match.
    return re.sub(r"\s+", " ", capture(scrollback))


def live_frame(rows=2):
    """The rows around the cursor -- the one prompt frame that is current.

    The prompt does not sit at the bottom of the pane: below it is only
    emptiness, and above it every past frame keeps whatever it showed
    forever. Assertions about "what the prompt says now" must anchor on the
    cursor row, which display-message reports.
    """
    out = capture().splitlines()
    y = int(pane().cmd("display-message", "-p", "#{cursor_y}").stdout[0])
    lo = max(0, y - rows + 1)
    return re.sub(r"\s+", " ", "\n".join(out[lo:y + 1]))


def crashed():
    pane_text = screen(scrollback=120)
    return [marker for marker in CRASH if marker in pane_text]


CASES = []


def case(name):
    def register(fn):
        CASES.append((name, fn))
        return fn
    return register


def fresh_prompt():
    # Escape lands in normal mode whatever happened -- but sent too soon
    # before the next key, prompt_toolkit merges the pair into Alt-i inside
    # its escape sequence timeout, so give the mode switch its own beat
    # before i enters insert. C-u then clears the line. Scrollback is
    # dropped too, so one case's traceback cannot satisfy another's crash
    # check.
    pane().cmd("clear-history")
    send("Escape", wait=0.6)
    send("i", "C-u", wait=0.8)


def raw_capture():
    """Capture with escape sequences intact -- for assertions about styling."""
    return "\n".join(pane().cmd("capture-pane", "-p", "-e").stdout)


def mode_label_styled():
    """Is any visible NOR/INS/SEL label painted in yellow? Waits for the
    label to exist first -- it first renders well over a second after the
    prompt does -- then reads *raw* bytes: `capture()` strips escapes, and
    the left prompt legitimately contains other yellow, so only the bytes
    immediately before a label occurrence prove anything."""
    end = time.time() + 8
    while time.time() < end:
        rows = pane().cmd("capture-pane", "-p", "-e").stdout
        for row in rows:
            for m2 in re.finditer(r"(NOR|INS|SEL)", row):
                before = row[max(0, m2.start() - 20):m2.start()]
                if re.search(r"\x1b\[1;38;5;223m|\x1b\[38;5;223m", before):
                    return True
        time.sleep(0.15)
    return False
    return False


@case("mode label carries its colour from the first frame")
def _():
    # No keys pressed: whatever the very first prompt rendered is what a
    # fresh shell shows, and that is exactly where the grey frame lived.
    return mode_label_styled() and not crashed()


@case("search opens and shows the history indicator")
def _():
    fresh_prompt()
    send("C-r")
    ok = "history" in screen()
    fresh_prompt()
    return ok


@case("accept without navigating lands the highlighted entry")
def _():
    fresh_prompt()
    send("echo navseed7", wait=1.2)
    # $COMPLETIONS_CONFIRM is True in this shell: with a completion menu
    # live, the first Enter confirms the selection and only the next one
    # submits. A submitted run shows the command echoed and then its
    # output -- "navseed7" twice on one screen.
    send("Enter", wait=0.9)
    if "navseed7 navseed7" not in screen():
        send("Enter", wait=1.2)
    send("C-r", "navs", wait=1.0)
    send("Enter", wait=1.0)                  # no arrows first: take index 0
    ok = "echo navseed7" in screen()
    fresh_prompt()
    return ok


@case("navigate down then accept does not crash and lands that entry")
def _():
    fresh_prompt()
    send("echo alpha-seed-1", wait=1.2)
    send("Enter", wait=1.2)
    send("echo beta-seed-2", wait=1.2)
    send("Enter", wait=1.2)
    send("C-r", "seed", wait=1.0)
    send("Down", wait=0.5)
    send("Enter", wait=1.0)
    ok = "beta-seed-2" in screen() and not crashed()
    fresh_prompt()
    return ok


@case("navigate up then accept works the same")
def _():
    fresh_prompt()
    send("C-r", "seed", wait=1.0)
    send("Down", wait=0.4)
    send("Up", wait=0.4)
    send("Enter", wait=1.0)
    ok = "alpha-seed-1" in screen() and not crashed()
    fresh_prompt()
    return ok


@case("escape after navigation restores the pre-search draft")
def _():
    fresh_prompt()
    send("draft-marker-9", wait=0.8)
    send("C-r", wait=0.8)
    send("Down", wait=0.5)
    send("Escape", wait=0.9)
    # Read the restored line off the screen; do not execute it -- running a
    # junk command prints xonsh command-not-found tracebacks that are shell
    # noise, not product crashes.
    return "draft-marker-9" in screen()


@case("search reaches history from earlier invocations")
def _():
    fresh_prompt()
    marker = f"oldsess-{int(time.time())}"
    send(f"echo {marker}", wait=1.0)
    # Enter until it actually ran; $COMPLETIONS_CONFIRM is True here.
    send("Enter", wait=0.9)
    if marker + " " + marker not in screen():
        send("Enter", wait=1.2)
    send("exit", wait=0.4)
    send("Enter", wait=1.5)                  # leave the shell for good
    # A clean exit takes the whole tmux session with it -- killing it again
    # is only for the case where something kept it alive.
    try:
        session().kill()
    except (RuntimeError, libtmux.exc.LibTmuxException):
        pass
    time.sleep(0.5)
    boot(BINARY[0])                          # a brand-new shell process
    fresh_prompt()
    send("C-r", marker, wait=1.0)            # full marker as exact prefix
    return marker in screen() and not crashed()


@case("slow command shows its seconds, the next fast one clears them")
def _():
    fresh_prompt()
    send("sleep 2", wait=0.5)
    send("Enter", wait=3.2)
    shown = "[2s]" in live_frame()
    send("echo done-fast", wait=0.5)
    send("Enter", wait=1.6)
    cleared = "[2s]" not in live_frame()
    return shown and cleared and not crashed()


@case("insert-mode tab completion selects without crashing")
def _():
    fresh_prompt()
    send("ech", wait=0.5)
    send("Tab", wait=0.8)
    send("Tab", wait=0.5)                    # cycle to next candidate
    send("Enter", wait=1.0)                  # accept selection into line
    ok = not crashed()
    fresh_prompt()
    return ok


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else None
    if binary is None:
        # The nix wrapper puts the shell under test on PATH; a bare checkout
        # run falls back to the usual out-link.
        binary = shutil.which("anyxonsh") or "/tmp/anyxonsh/bin/anyxonsh"
    BINARY[0] = binary
    pattern = re.compile(os.environ.get("CASES", "."))
    boot(binary)
    failures = 0
    try:
        for name, fn in CASES:
            if not pattern.search(name):
                continue
            try:
                ok = fn()
            except Exception as err:  # noqa: BLE001 - report, keep driving
                print(f"FAIL {name}: raised {err!r}")
                failures += 1
                continue
            crash_note = ""
            leftover = crashed()
            if leftover:
                ok = False
                crash_note = f" (crash markers: {leftover})"
            if ok:
                print("PASS " + name)
            else:
                print("FAIL " + name + crash_note)
                print("--- pane at failure ---")
                print(screen(scrollback=60))
                print("--- end pane ---")
            failures += 0 if ok else 1
    finally:
        try:
            session().kill()
        except Exception:
            pass
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
