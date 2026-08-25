"""Entry point for the ``anyxonsh`` console script.

Points xonsh at this package's bundled ``rc.xsh`` and then hands over to
xonsh's own ``main``. Running xonsh in-process rather than ``exec``ing it keeps
us inside the venv the Nix build produced, so ``sys.prefix`` -- and therefore
every import xonsh does -- resolves against the flat ``site-packages``
``mkVirtualEnv`` built.
"""

from __future__ import annotations

import os
import sys
from importlib.resources import as_file, files
from pathlib import Path


def _user_rc_files() -> list[Path]:
    """User run-control files, loaded after the bundled one so they win.

    Set ``ANYXONSH_NO_USER_RC=1`` for a hermetic shell that ignores anything
    outside the Nix closure -- useful when reproducing a bug report.
    """
    if os.environ.get("ANYXONSH_NO_USER_RC"):
        return []

    xdg = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    candidates = [
        Path(xdg).expanduser() / "xonsh" / "rc.xsh",
        Path("~/.xonshrc").expanduser(),
    ]
    return [p for p in candidates if p.is_file()]


def main(argv: list[str] | None = None) -> int:
    from xonsh.main import main as xonsh_main

    # `as_file` because the rc may live inside a zip in a non-Nix install; under
    # Nix it is a plain store path and this is a no-op. The context manager has
    # to stay open for the whole xonsh session, hence the nesting below.
    with as_file(files("anyxonsh").joinpath("rc.xsh")) as bundled_rc:
        rc_files = [str(bundled_rc), *(str(p) for p in _user_rc_files())]

        # xonsh reads $XONSHRC as an os.pathsep-separated list. Respect an
        # explicit caller-supplied value rather than silently overriding it.
        if "XONSHRC" not in os.environ:
            os.environ["XONSHRC"] = os.pathsep.join(rc_files)

        return xonsh_main(argv if argv is not None else sys.argv[1:]) or 0


if __name__ == "__main__":
    raise SystemExit(main())
