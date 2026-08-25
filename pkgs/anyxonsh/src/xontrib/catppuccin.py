"""Catppuccin Mocha as the shell's colour scheme.

    xontrib load catppuccin

The xontrib entry point and nothing else. Everything it does lives in the
`xontrib_catppuccin` package next door -- the split xonsh's own packages use
(`xontrib/term_integration.py` in front of `xontrib_term_integrations/`), and
the reason is import cost: this module is imported by `get_xontribs()` during
plain *discovery*, so anything heavier than a docstring would be paid by every
`xontrib list` whether the theme is loaded or not. The implementation pulls in
pygments and Catppuccin's palette, neither of which a shell that is not being
themed should have to load.

`xontrib` is a namespace package: it deliberately has no `__init__.py`, so
several distributions can drop modules into it.
"""

from __future__ import annotations

#: Nothing is exported into the shell's global namespace. The handle returned
#: by `_load_xontrib_` below is the only name this adds.
__all__ = ()


def _load_xontrib_(xsh, **_):
    """Register the style and switch to it. Returns the shell context to merge."""
    from xontrib_catppuccin import setup

    return {"__catppuccin__": setup()}


def _unload_xontrib_(xsh, **_):
    """Undo `_load_xontrib_`, for `xontrib unload catppuccin`.

    The registration itself is not undone -- xonsh offers no way to take a
    style back out of `STYLES`, and leaving it there costs nothing but a name
    in `xonfig styles`. What is undone is the part a user would notice:
    `$XONSH_COLOR_STYLE` goes back to whatever it said before.
    """
    installation = xsh.ctx.pop("__catppuccin__", None)
    if installation is not None:
        installation.uninstall()
