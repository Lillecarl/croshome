"""Which binding a key release fires. No IO: the device loop feeds it events."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from evdev import KeyEvent

from .config import code

if TYPE_CHECKING:
    from collections.abc import Iterable

    from .config import Action, Binding


@dataclass
class Chords:
    """Bindings fire on release.

    A key that some binding holds is a modifier. Released after another key
    went down while it was held, it fires nothing: it was a modifier, not a
    tap. With a modifier held, only that modifier's bindings fire.
    """

    table: dict[tuple[int | None, int], Action]
    modifiers: frozenset[int]
    held: list[int] = field(default_factory=list)
    used: set[int] = field(default_factory=set)

    @classmethod
    def of(cls, bindings: Iterable[Binding]) -> Chords:
        table = {
            (code(b.hold) if b.hold else None, code(b.key)): b.action for b in bindings
        }
        return cls(table, frozenset(h for h, _ in table if h is not None))

    def feed(self, key: int, value: int) -> Action | None:
        if value == KeyEvent.key_down:
            if key not in self.held:
                self.used.update(m for m in self.held if m in self.modifiers)
                self.held.append(key)
            return None
        if value != KeyEvent.key_up or key not in self.held:
            return None
        self.held.remove(key)
        if key in self.used:
            self.used.discard(key)
            return None
        modifier = next((m for m in self.held if m in self.modifiers), None)
        return self.table.get((modifier, key))

    def reset(self) -> None:
        self.held.clear()
        self.used.clear()
