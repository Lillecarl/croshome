"""A model at the xonsh prompt.

    xontrib load pai

    : what changed in this repo today?
    :help

The xontrib entry point and nothing else. Everything it does lives in the
`xontrib_pai` package next door -- the split xonsh's own packages use
(`xontrib/term_integration.py` in front of `xontrib_term_integrations/`), and
the reason is import cost: this module is imported by `get_xontribs()` during
plain *discovery*, so anything heavier than a docstring would be paid by every
`xontrib list` whether pai is loaded or not. That matters more here than it does
for `helix`, because the thing behind this one is pydantic-ai, which costs about
half a second to import.

`xontrib` is a namespace package: it deliberately has no `__init__.py`, so
several distributions can drop modules into it.
"""

from __future__ import annotations

__all__ = ()


def _load_xontrib_(xsh, **_):
    """Install the prefix hook. Returns the ctx `xontrib load` merges in."""
    from xontrib_pai import setup

    return {"__pai__": setup()}


def _unload_xontrib_(xsh, **_):
    """Undo `_load_xontrib_`, for `xontrib unload pai`.

    Unlike the helix xontrib this one comes off cleanly: the whole integration
    is a single `on_transform_command` handler, and `xonsh.events.Event.discard`
    takes it back out. The next `:` line is an ordinary command again -- and
    fails the way it would have before, since `:` is not a program.
    """
    installation = xsh.ctx.pop("__pai__", None)
    if installation is not None:
        installation.uninstall()
