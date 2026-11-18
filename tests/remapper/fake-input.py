"""A fake numpad, keyboard and mouse, driven by lines on a FIFO.

`tap KEY_A` presses and releases a key (KP keys on the numpad, the rest on
the keyboard); `move 5` moves the mouse right.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from evdev import UInput, ecodes

VENDOR = 0x1234


def main(fifo: Path) -> None:
    pad = UInput(
        {ecodes.EV_KEY: [ecodes.KEY_KP0, ecodes.KEY_KP1, ecodes.KEY_KP2]},
        name="fake numpad",
        vendor=VENDOR,
        product=1,
    )
    keyboard = UInput({ecodes.EV_KEY: [ecodes.KEY_A, ecodes.KEY_B]}, name="fake keyboard", vendor=VENDOR, product=2)
    mouse = UInput(
        {ecodes.EV_KEY: [ecodes.BTN_LEFT, ecodes.BTN_RIGHT], ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y]},
        name="fake mouse",
        vendor=VENDOR,
        product=3,
    )
    fifo.unlink(missing_ok=True)
    os.mkfifo(fifo)
    print("ready", flush=True)
    while True:
        with fifo.open() as lines:
            for line in lines:
                verb, arg = line.split()
                if verb == "tap":
                    key = ecodes.ecodes[arg]
                    dev = pad if arg.startswith("KEY_KP") else keyboard
                    for value in (1, 0):
                        dev.write(ecodes.EV_KEY, key, value)
                        dev.syn()
                elif verb == "move":
                    mouse.write(ecodes.EV_REL, ecodes.REL_X, int(arg))
                    mouse.syn()
                print(line.strip(), flush=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
