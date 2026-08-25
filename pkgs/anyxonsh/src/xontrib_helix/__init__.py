"""Helix-style modal editing for xonsh's prompt_toolkit line editor.

The implementation behind the `helix` xontrib; `xontrib/helix.py` is the entry
point that loads it. Three layers, deliberately separable:

* `chars`, `selection`, `movement` -- ports of the corresponding helix-core
  modules. Pure functions over `(text, Range)`.
* `editor` -- modes, registers, undo and the key dispatch state machine. Still
  pure: it reports anything shell-shaped back as a `ShellRequest`.
* `integration` -- the only module that imports prompt_toolkit or xonsh.

Importing this package pulls in the first two layers and nothing else, so it
costs nothing at shell startup until a prompt is actually created.
"""

from __future__ import annotations

from .editor import Editor, Mode, ShellRequest
from .keys import parse_keys
from .selection import Direction, Range

__all__ = [
    "Direction",
    "Editor",
    "Mode",
    "Range",
    "ShellRequest",
    "parse_keys",
    "setup",
]


def setup(**kwargs):
    """Install the Helix bindings into the running xonsh shell.

    Imported lazily: `from xontrib_helix import setup` must stay cheap, and
    `integration` is the module that drags in prompt_toolkit.
    """
    from .integration import setup as _setup

    return _setup(**kwargs)
