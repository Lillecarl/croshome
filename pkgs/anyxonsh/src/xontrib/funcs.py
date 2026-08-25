"""fish's `funced` / `funcsave`, as a xontrib.

    xontrib load funcs

The xontrib entry point and nothing else -- see `xontrib_funcs/` for the
implementation, following the same split as `catppuccin`: this module is
imported by plain discovery (`xontrib list`), so it stays a docstring plus a
two-line loader.
"""

from __future__ import annotations

__all__ = ()


def _load_xontrib_(xsh, **_):
    """Install the funced/funcsave aliases and start watching the funcs dir."""
    from xontrib_funcs import setup

    setup()
    return {}
