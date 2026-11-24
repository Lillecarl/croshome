"""Caps Lock as Ctrl, or as Esc when tapped alone. No IO: the router feeds it keys."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final

from evdev import KeyEvent, ecodes

TAP: Final = 0.5

# (key, value) pairs, each its own report.
Keys = list[tuple[int, int]]


def _tap(key: int) -> Keys:
    return [(key, KeyEvent.key_down), (key, KeyEvent.key_up)]


@dataclass
class CapsMap:
    """Caps+Esc is Caps Lock. A tap is a press under TAP seconds with no other key."""

    pressed_at: float | None = None
    alone: bool = False
    swallowed: set[int] = field(default_factory=set)

    def feed(self, key: int, value: int, at: float) -> Keys:
        if key == ecodes.KEY_CAPSLOCK:
            return self._caps(value, at)
        if value == KeyEvent.key_down:
            self.alone = False
            if key == ecodes.KEY_ESC and self.pressed_at is not None:
                self.swallowed.add(key)
                return _tap(ecodes.KEY_CAPSLOCK)
        if key in self.swallowed:
            if value == KeyEvent.key_up:
                self.swallowed.discard(key)
            return []
        return [(key, value)]

    def _caps(self, value: int, at: float) -> Keys:
        if value == KeyEvent.key_down:
            self.pressed_at, self.alone = at, True
        tapped = (
            value == KeyEvent.key_up
            and self.alone
            and self.pressed_at is not None
            and at - self.pressed_at < TAP
        )
        if value == KeyEvent.key_up:
            self.pressed_at, self.alone = None, False
        keys: Keys = [(ecodes.KEY_LEFTCTRL, value)]
        return keys + _tap(ecodes.KEY_ESC) if tapped else keys

    def reset(self) -> None:
        self.pressed_at, self.alone = None, False
        self.swallowed.clear()
