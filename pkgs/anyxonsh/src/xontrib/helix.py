"""Helix-style modal editing at the xonsh prompt.

    xontrib load helix

The xontrib entry point and nothing else. Everything it does lives in the
`xontrib_helix` package next door -- the split xonsh's own packages use
(`xontrib/term_integration.py` in front of `xontrib_term_integrations/`), and
the reason is import cost: this module is imported by `get_xontribs()` during
plain *discovery*, so anything heavier than a docstring would be paid by every
`xontrib list` whether Helix is loaded or not.

`xontrib` is a namespace package: it deliberately has no `__init__.py`, so
several distributions can drop modules into it.
"""

from __future__ import annotations

#: Nothing is exported into the shell's global namespace. The handle returned
#: by `_load_xontrib_` below is the only name this adds.
__all__ = ()


def _load_xontrib_(xsh, **_):
    """Install the bindings. Returns the shell context `xontrib load` merges in."""
    from xontrib_helix import setup

    return {"__helix__": setup()}


def _unload_xontrib_(xsh, **_):
    """Undo `_load_xontrib_`, for `xontrib unload helix`.

    prompt_toolkit offers no way to take a binding back out of a registry, so a
    live session keeps ours -- they are switched off by their filter instead,
    and the next keystroke goes to xonsh's own emacs bindings.
    """
    installation = xsh.ctx.pop("__helix__", None)
    if installation is not None:
        installation.uninstall()
