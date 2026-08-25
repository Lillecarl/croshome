"""fish's `funced` and `funcsave`, for xonsh.

The workflow this exists for:

    funced greet     # opens $EDITOR; on exit the function is callable *now*
    funcsave greet   # persists it, so every other anyxonsh shell has it too

Storage is a directory of one-function-per-file xonsh snippets, named after
the function they define -- ``greet.xsh`` must define ``greet``. Finding
functions by file name (rather than tracking what each file defines) is the
whole design: it makes autoload, live re-scan and deletion all trivial, at the
cost of one convention.

How functions become callable: everything here goes through
`XSH.execer.exec(src, glbs=XSH.ctx, filename=path)`. Two properties matter.
Passing the shell's own ctx dict means definitions land where commands run.
Passing the real path as `filename` populates linecache, so `inspect.getsource`
works on anything loaded from disk -- which is what makes `funcsave` able to
serialise an autoloaded function without having seen its text before.

`funcsave` honesty note: a function typed straight at the prompt has no source
anywhere (linecache has nothing, and nothing recorded it). That case errors,
pointing at `funced`. Functions from `funced` are kept in a session registry;
functions from disk are recovered via getsource. Nothing silently saves a
guess.
"""

from __future__ import annotations

import inspect
import os
import shutil
import subprocess
import tempfile

__all__ = ()

#: New files start with something that runs and says what to do next. The
#: docstring position matters: it is what `help(greet)` shows.
TEMPLATE = '''def {name}():
    """Describe what {name} does."""
    print("{name}: not written yet -- edit me with funced {name}")
'''

_SESSION_SRC: dict[str, str] = {}
_SCAN: dict[str, float] = {}


def _funcs_dir() -> str:
    """The directory funcs are stored in, created on first use."""
    d = os.environ.get("ANYXONSH_FUNCS_DIR") or os.path.expanduser(
        "~/.config/xonsh/funcs"
    )
    os.makedirs(d, exist_ok=True)
    return d


def _path(name: str) -> str:
    if not name.isidentifier():
        raise ValueError(f"not a valid function name: {name!r}")
    return os.path.join(_funcs_dir(), f"{name}.xsh")


def _exec_file(path: str) -> None:
    """Execute one funcs file into the shell context, under its own name."""
    from xonsh.built_ins import XSH

    with open(path) as fh:
        src = fh.read()
    XSH.execer.exec(src, glbs=XSH.ctx, filename=path)


def _names_on_disk() -> dict[str, float]:
    """Every *.xsh in the funcs dir, as {stem: mtime}."""
    d = _funcs_dir()
    return {
        fn[:-4]: os.stat(os.path.join(d, fn)).st_mtime
        for fn in os.listdir(d)
        if fn.endswith(".xsh") and os.path.isfile(os.path.join(d, fn))
    }


def autoload() -> None:
    """Load every saved function. Called once, when the xontrib loads."""
    for name in sorted(_names_on_disk()):
        try:
            load(name)
        except Exception as exc:  # noqa: BLE001 -- one bad file must not take the shell down
            print(f"funcs: failed to load {name}.xsh: {exc}")


def load(name: str) -> None:
    """(Re)execute one funcs file and record its mtime as seen."""
    path = _path(name)
    _exec_file(path)
    _SCAN[name] = os.stat(path).st_mtime


def sync() -> None:
    """Pick up files other shells wrote, changed or deleted.

    Runs after every command. Cost is one listdir plus a stat per file --
    no subprocess, no watcher thread. A function another shell just saved is
    therefore callable here by its next command, which is the "shared between
    all shells" half of the promise.
    """
    now = _names_on_disk()
    for name in sorted(set(now) - set(_SCAN)):
        try:
            load(name)
        except Exception as exc:  # noqa: BLE001
            print(f"funcs: failed to load new file {name}.xsh: {exc}")
    for name in [n for n, m in now.items() if m != _SCAN.get(n)]:
        try:
            load(name)
        except Exception as exc:  # noqa: BLE001
            print(f"funcs: failed to reload {name}.xsh: {exc}")
    for name in set(_SCAN) - set(now):
        # Deleted elsewhere: gone from disk means gone from here too.
        from xonsh.built_ins import XSH

        XSH.ctx.pop(name, None)
        del _SCAN[name]


def funced(args: list[str]) -> None:
    """Usage: funced NAME

    Opens $EDITOR on NAME's source -- the saved file if it exists, otherwise
    a template. When the editor exits cleanly, the edited source executes in
    this shell immediately. Nothing is persisted until `funcsave NAME`.
    """
    if len(args) != 1:
        print("usage: funced NAME")
        return
    name = args[0]
    path = _path(name)

    if os.path.exists(path):
        with open(path) as fh:
            buf = fh.read()
    else:
        buf = _SESSION_SRC.get(name) or TEMPLATE.format(name=name)

    editor = _editor()
    fd, tmp = tempfile.mkstemp(prefix=f"funced-{name}-", suffix=".xsh")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(buf)
        try:
            rc = subprocess.run([editor, tmp]).returncode
        except OSError as exc:
            print(f"funced: cannot run editor {editor!r}: {exc}")
            return
        if rc != 0:
            print(f"funced: editor exited {rc}; keeping the old definition")
            return
        with open(tmp) as fh:
            new = fh.read()
    finally:
        os.unlink(tmp)

    # Executed under a <funced> filename, deliberately not under the target:
    # linecache would then serve pre-save content to getsource behind funcsave's
    # back. The session registry is the honest record instead.
    from xonsh.built_ins import XSH

    XSH.execer.exec(new, glbs=XSH.ctx, filename=f"<funced:{name}>")
    _SESSION_SRC[name] = new
    print(f"funced: {name} is callable in this shell; use 'funcsave {name}' to share it")


def funcsave(args: list[str]) -> None:
    """Usage: funcsave NAME

    Writes NAME's current definition into the funcs dir. Every other anyxonsh
    shell picks it up by its next command, and every future shell starts with
    it.
    """
    if len(args) != 1:
        print("usage: funcsave NAME")
        return
    name = args[0]
    from xonsh.built_ins import XSH

    fn = XSH.ctx.get(name)
    if not callable(fn):
        print(f"funcsave: no callable named {name!r} in this shell")
        return

    src = _SESSION_SRC.get(name)
    if src is None:
        try:
            src = inspect.getsource(fn)
        except (OSError, TypeError):
            src = None
    if src is None:
        print(
            f"funcsave: cannot read the source of {name!r}. "
            f"Define it with 'funced {name}' first, then save."
        )
        return

    path = _path(name)
    with open(path, "w") as fh:
        fh.write(src)
    _SCAN[name] = os.stat(path).st_mtime
    print(f"funcsave: {name} -> {path}")


def _editor() -> str:
    # An explicit $EDITOR is honoured verbatim -- second-guessing it (is it on
    # PATH?) breaks every editor given as an absolute path, and turns a typo'd
    # or non-executable one into a mystery fallback. Trust it; failures surface
    # from the run below with the real error.
    editor = os.environ.get("EDITOR")
    if editor:
        return editor
    for candidate in ("nvim", "vim", "vi", "nano"):
        if shutil.which(candidate):
            return candidate
    return "true"  # no editor anywhere: editing becomes a no-op that still applies the buffer


def setup() -> None:
    """Wire everything up: aliases, autoload, and the post-command sync."""
    from xonsh.built_ins import XSH
    from xonsh.events import events

    XSH.aliases["funced"] = funced
    XSH.aliases["funcsave"] = funcsave

    autoload()

    @events.on_post_command
    def _funcs_sync(**_):
        sync()
