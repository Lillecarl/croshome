"""Drive a real anyxonsh in a scratch tmux session and check completion flows.

Usage:

    python3 tests/completions.py /path/to/anyxonsh

Every case sends real keys and reads the pane back with tmux capture-pane,
so what is asserted is what a person would see -- not internals. A case
fails on a missing screen expectation or on any traceback text appearing
anywhere in the scrollback.
"""

import os
import re
import subprocess
import sys
import time

SESSION = "anyxonsh-test"
CRASH = ("Traceback", "Press ENTER to continue", "Unhandled exception")
TRACE = bool(os.environ.get("TRACE"))


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def boot(binary):
    sh("tmux", "kill-session", "-t", SESSION)
    sh("tmux", "new-session", "-d", "-s", SESSION, "-x", "180", "-y", "40",
       binary)
    end = time.time() + 30
    while time.time() < end:
        if "@\n" in sh("tmux", "capture-pane", "-p", "-t", SESSION).stdout:
            break
        time.sleep(0.3)
    time.sleep(1.0)


def send(*keys, wait=0.6):
    for k in keys:
        sh("tmux", "send-keys", "-t", SESSION, k)
        time.sleep(0.08)
        if TRACE:
            print(f"[trace] after {k!r}: {screen()}")
    time.sleep(wait)
    if TRACE:
        print(f"[trace] settle({wait}): {screen()}")


def screen(scrollback=0):
    args = ["tmux", "capture-pane", "-p", "-t", SESSION]
    if scrollback:
        args += ["-S", str(-scrollback)]
    out = sh(*args).stdout
    # Collapse runs of blanks so redraw residue cannot satisfy a match.
    return re.sub(r"\s+", " ", out)


def crashed():
    pane = screen(scrollback=120)
    return [marker for marker in CRASH if marker in pane]


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
    sh("tmux", "clear-history", "-t", SESSION)
    send("Escape", wait=0.6)
    send("i", "C-u", wait=0.8)


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
    pane = screen()
    ok = "beta-seed-2" in pane and not crashed()
    fresh_prompt()
    return ok


@case("navigate up then accept works the same")
def _():
    fresh_prompt()
    send("C-r", "seed", wait=1.0)
    send("Down", wait=0.4)
    send("Up", wait=0.4)
    send("Enter", wait=1.0)
    pane = screen()
    ok = "alpha-seed-1" in pane and not crashed()
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
    binary = sys.argv[1] if len(sys.argv) > 1 else "/tmp/anyxonsh/bin/anyxonsh"
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
        sh("tmux", "kill-session", "-t", SESSION)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
