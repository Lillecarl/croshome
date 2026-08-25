"""A model at the xonsh prompt, behind a `:` prefix.

The implementation behind the `pai` xontrib; `xontrib/pai.py` is the entry point
that loads it. Three layers, and only the last one knows about xonsh:

* `prefix`   -- what counts as a line addressed to the model. Pure.
* `workspace`-- which directory the file tools may touch. Pure.
* `agent`    -- the pydantic-ai conversation, arranged so the prompt cache holds.
* `integration` -- the `on_transform_command` hook and the `:` commands.

Importing this package must stay cheap: `import pydantic_ai` alone is ~500 ms,
which is more than the whole shell's startup budget. Nothing here imports it at
module scope, and `agent` defers it into the functions that need it, so the cost
is paid on the first request rather than at every prompt.
"""

from __future__ import annotations

from .prefix import PREFIX, Request, parse
from .workspace import choose_root

__all__ = [
    "PREFIX",
    "Request",
    "choose_root",
    "parse",
    "setup",
]


def setup(**kwargs):
    """Install the prefix hook into the running xonsh shell.

    Imported lazily: `integration` is the module that drags in xonsh.
    """
    from .integration import setup as _setup

    return _setup(**kwargs)
