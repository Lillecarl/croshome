"""Helix-style modal editing for xonsh's prompt_toolkit line editor.

The implementation behind the `helix` xontrib; `xontrib/helix.py` is the entry
point that loads it. The editor and its prompt_toolkit bindings are ptkhx's,
from pyterm, where real Helix judges the keymap. What is here is xonsh's:

* `integration` -- the bindings put on xonsh's prompt, history search on
  Ctrl-R, the `{helix_mode}` and `{helix_pending}` prompt fields.
* `search` -- the completer behind history search.
* `terminal`, `keyboard` -- what is asked of the terminal before
  prompt_toolkit owns it.

Importing this package costs nothing at shell startup until a prompt is
actually created.
"""

from __future__ import annotations

__all__ = ["setup"]


def setup(**kwargs):
    """Install the Helix bindings into the running xonsh shell.

    Imported lazily: `from xontrib_helix import setup` must stay cheap, and
    `integration` is the module that drags in prompt_toolkit.
    """
    from .integration import setup as _setup

    return _setup(**kwargs)
