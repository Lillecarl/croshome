"""A complete xonsh environment, bundled with Nix.

The Nix side builds a flat virtualenv containing xonsh, this package and
whatever else was requested, then exposes :func:`anyxonsh.__main__.main` as the
``anyxonsh`` console script. Everything user-visible lives in ``rc.xsh``.
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
