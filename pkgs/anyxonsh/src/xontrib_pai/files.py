"""File tools, over named mounts rather than one root.

Replaces pydantic-ai-harness's `FileSystem`, which is a good capability for the
job it was built for and the wrong shape for this one. Two mismatches, neither
configurable away:

* **One root.** `root_dir` is a single path, so the workspace and the bundled
  xonsh documentation cannot both be reachable. Rooting at `/` to cover both
  makes every path the model handles look like `home/you/Code/proj/src/x.py`,
  and see below for what it does to search.
* **Unbounded walks.** `search_files` does `sorted(resolved.rglob('*'))` with
  `path` defaulting to `'.'`. Measured at root `/`: 1.1 million entries in 20
  seconds without finishing, materialised into a list before anything is
  filtered. The allowlist gates results, not enumeration.

So: a small mount table. Every path is `<mount>/<rest>` -- `repo/src/main.py`,
`docs/tutorial.rst` -- which gives the model one obvious vocabulary, keeps each
walk inside one subtree, and leaves room to mount more later.

What is deliberately *not* here is a security boundary. Containment checks below
stop the model wandering off by accident; they are not load-bearing, because
`run_xonsh` next door will read anything at all once you approve it. Human in
the loop is the control.

Mount *paths* never appear in a tool signature or docstring, only mount
*names* -- so switching repository does not rewrite the tool definitions, which
would invalidate every cached conversation. The current paths are told to the
model in the per-message context block instead.
"""

from __future__ import annotations

import hashlib
import os
import re
from dataclasses import dataclass
from pathlib import Path

#: Where the bundled xonsh documentation lives. Set by the Nix wrapper; unset in
#: a plain checkout, which is why the docs mount is optional everywhere.
DOCS_VAR = "XONTRIB_PAI_XONSH_DOCS"

#: Never walked into. Not a rule about what may be read -- an explicit
#: `repo/.git/config` still resolves -- just what a search should not drown in.
SKIP_DIRS = frozenset(
    {".git", ".jj", "__pycache__", "node_modules", ".venv", ".direnv", ".mypy_cache"}
)

MAX_READ_LINES = 400
MAX_MATCHES = 80
MAX_LISTING = 200
#: Anything larger is almost certainly not prose or code.
MAX_BYTES = 2_000_000


@dataclass(frozen=True)
class Mount:
    name: str
    path: Path
    writable: bool
    description: str


def mounts(workspace: Path) -> dict[str, Mount]:
    """The mount table for one request, in a fixed order."""
    table = {
        "repo": Mount("repo", workspace, True, "the current project"),
    }
    docs = os.environ.get(DOCS_VAR)
    if docs and Path(docs).is_dir():
        table["docs"] = Mount(
            "docs", Path(docs), False, "the xonsh documentation, read-only"
        )
    return table


#: Every tool result that reports a failure starts with this.
#:
#: The tools return their problems rather than raising them -- a model that is
#: told "that text appears twice" can fix its call, where an exception would
#: just end the turn. The cost is that a failure and a success are both a
#: string, so `progress` cannot tell them apart to report the failure to the
#: user. Hence a marker: one constant, checked in one place, rather than a list
#: of message prefixes kept in step by hand.
ERROR = "Error: "


def _fail(message: str) -> str:
    """A tool result that says what went wrong."""
    return f"{ERROR}{message}"


def failed(result) -> bool:
    """Did a tool result report a failure?"""
    return isinstance(result, str) and result.startswith(ERROR)


class PathError(Exception):
    """A path that does not name anything reachable."""


def resolve(
    table: dict[str, Mount], spec: str, *, write: bool = False
) -> tuple[Mount, Path]:
    """Turn `repo/src/x.py` into a real path, or explain why not."""
    spec = spec.strip().lstrip("/")
    if not spec:
        raise PathError("Empty path. Use <mount>/<path>, e.g. repo/README.md.")
    head, _, rest = spec.partition("/")
    mount = table.get(head)
    if mount is None:
        known = ", ".join(table)
        raise PathError(f"Unknown mount {head!r}. Available mounts: {known}.")
    if write and not mount.writable:
        raise PathError(f"The {mount.name!r} mount is read-only.")

    root = mount.path.resolve()
    target = (root / rest).resolve() if rest else root
    if not (target == root or target.is_relative_to(root)):
        raise PathError(f"{spec!r} resolves outside the {mount.name!r} mount.")
    return mount, target


def _show(table: dict[str, Mount], mount: Mount, path: Path) -> str:
    """The name the model used, reconstructed for output."""
    root = mount.path.resolve()
    rel = path.relative_to(root) if path != root else Path()
    return f"{mount.name}/{rel}" if str(rel) != "." else mount.name


def _is_text(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return b"\0" not in handle.read(4096)
    except OSError:
        return False


def _walk(root: Path):
    """Every file under `root`, skipping the directories nobody means."""
    for current, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(names):
            yield Path(current) / name


def digest(text: str) -> str:
    """Short content hash, so an edit can notice it was working from stale text."""
    return hashlib.sha256(text.encode()).hexdigest()[:12]


# --- The tools --------------------------------------------------------------
#
# Each takes the mount table as its first argument, which the agent layer binds
# per request. The model sees only the arguments after it.


def _files_list(table: dict[str, Mount], path: str = "") -> str:
    """List a directory."""
    if not path.strip():
        return "\n".join(f"{m.name}/  -- {m.description}" for m in table.values())
    try:
        mount, target = resolve(table, path)
    except PathError as exc:
        return _fail(str(exc))
    if not target.is_dir():
        return _fail(f"{path!r} is not a directory.")
    rows = []
    for entry in sorted(target.iterdir(), key=lambda p: (p.is_file(), p.name)):
        if entry.name in SKIP_DIRS:
            continue
        if entry.is_dir():
            rows.append(f"{entry.name}/")
        else:
            try:
                rows.append(f"{entry.name}  ({entry.stat().st_size}b)")
            except OSError:
                rows.append(entry.name)
        if len(rows) >= MAX_LISTING:
            rows.append(f"[stopped at {MAX_LISTING} entries]")
            break
    return "\n".join(rows) if rows else "(empty)"


def _files_read(
    table: dict[str, Mount], path: str, offset: int = 1, limit: int = 0
) -> str:
    """Read a file, numbered from `offset`."""
    try:
        mount, target = resolve(table, path)
    except PathError as exc:
        return _fail(str(exc))
    if not target.is_file():
        return _fail(f"{path!r} is not a file.")
    try:
        if target.stat().st_size > MAX_BYTES:
            return _fail(f"{path!r} is too large to read ({target.stat().st_size} b).")
        if not _is_text(target):
            return _fail(f"{path!r} looks like a binary file.")
        text = target.read_text(errors="replace")
    except OSError as exc:
        return _fail(f"Could not read {path!r}: {exc}")

    lines = text.splitlines()
    limit = limit if limit > 0 else MAX_READ_LINES
    start = max(1, offset)
    chunk = lines[start - 1 : start - 1 + limit]
    body = "\n".join(f"{start + i:6}  {line}" for i, line in enumerate(chunk))
    header = f"{path} ({len(lines)} lines, hash {digest(text)})"
    shown_to = start + len(chunk) - 1
    if shown_to < len(lines):
        body += f"\n[lines {shown_to + 1}-{len(lines)} not shown; re-read with offset]"
    return f"{header}\n{body}"


def _files_search(
    table: dict[str, Mount], pattern: str, path: str = "repo", glob: str = ""
) -> str:
    """Search file contents for a regular expression."""
    try:
        mount, target = resolve(table, path)
    except PathError as exc:
        return _fail(str(exc))
    try:
        rx = re.compile(pattern)
    except re.error as exc:
        return _fail(f"Not a valid regular expression: {exc}")

    files = [target] if target.is_file() else _walk(target)
    hits: list[str] = []
    for candidate in files:
        if glob and not candidate.match(glob):
            continue
        try:
            if candidate.stat().st_size > MAX_BYTES or not _is_text(candidate):
                continue
            text = candidate.read_text(errors="replace")
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if rx.search(line):
                where = _show(table, mount, candidate)
                hits.append(f"{where}:{number}: {line.strip()[:200]}")
                if len(hits) >= MAX_MATCHES:
                    hits.append(f"[stopped at {MAX_MATCHES} matches; narrow it]")
                    return "\n".join(hits)
    return "\n".join(hits) if hits else f"No matches for {pattern!r} under {path}."


def _files_edit(
    table: dict[str, Mount],
    path: str,
    old_text: str,
    new_text: str,
    expected_hash: str = "",
) -> str:
    """Replace an exact string that occurs once."""
    try:
        mount, target = resolve(table, path, write=True)
    except PathError as exc:
        return _fail(str(exc))
    if not target.is_file():
        return _fail(f"{path!r} is not a file.")
    try:
        text = target.read_text(errors="replace")
    except OSError as exc:
        return _fail(f"Could not read {path!r}: {exc}")

    if expected_hash and digest(text) != expected_hash:
        return _fail(
            f"{path!r} has changed since you read it "
            f"(now {digest(text)}). Re-read it before editing."
        )
    found = text.count(old_text)
    if found == 0:
        return _fail(f"That exact text does not appear in {path!r}.")
    if found > 1:
        return _fail(f"That text appears {found} times in {path!r}; add context.")
    updated = text.replace(old_text, new_text)
    try:
        target.write_text(updated)
    except OSError as exc:
        return _fail(f"Could not write {path!r}: {exc}")
    return f"Edited {path} (now hash {digest(updated)})."


def _files_write(
    table: dict[str, Mount], path: str, content: str, expected_hash: str = ""
) -> str:
    """Create or overwrite a file."""
    try:
        mount, target = resolve(table, path, write=True)
    except PathError as exc:
        return _fail(str(exc))
    if target.exists():
        try:
            current = target.read_text(errors="replace")
        except OSError:
            current = None
        if current is not None and expected_hash and digest(current) != expected_hash:
            return _fail(
                f"{path!r} has changed since you read it "
                f"(now {digest(current)}). Re-read it before overwriting."
            )
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    except OSError as exc:
        return _fail(f"Could not write {path!r}: {exc}")
    return f"Wrote {path} ({len(content.splitlines())} lines, hash {digest(content)})."


def _peek(table: dict[str, Mount], path: str) -> str:
    """The current text of a file, or empty if there is not one to read.

    Only for showing a diff afterwards, so every failure is the same answer:
    nothing to compare against.
    """
    try:
        _, target = resolve(table, path)
        if target.is_file() and target.stat().st_size <= MAX_BYTES and _is_text(target):
            return target.read_text(errors="replace")
    except (PathError, OSError):
        pass
    return ""


def _changed(table: dict[str, Mount], path: str, action, *args) -> str:
    """Run a writing tool, then show the user what it did to the file.

    A read is reported by its path alone; a write is reported by its diff. That
    asymmetry is the point -- reads are the model's business and would bury the
    terminal, but a change to the user's files is something they should see
    without having to go and ask `git`.

    The diff is derived here rather than from the tool's arguments because the
    two disagree in the cases that matter: `write_file` sends the whole new file
    and no old one, `edit_file` sends a fragment, and either may refuse to do
    anything at all. Reading around the call reports what actually happened.
    """
    from .progress import diff

    before = _peek(table, path)
    result = action(table, *args)
    after = _peek(table, path)
    if after != before:
        diff(path, before, after)
    return result


def bind(workspace: Path) -> list:
    """The tools as the model sees them, with the mount table closed over.

    The wrappers carry the model-facing docstrings because that is what
    pydantic-ai turns into tool descriptions. They are also what keeps the
    schemas free of the mount *paths*: only names appear, so moving to another
    repository rebuilds the agent without changing a single byte of the request
    prefix.

    Returned in a fixed order. Tool order is part of that prefix, so sorting it
    by accident later would silently cost every cached conversation.
    """
    table = mounts(workspace)
    names = ", ".join(f"{m.name}/ ({m.description})" for m in table.values())

    def list_files(path: str = "") -> str:
        """List a directory, or the available mounts.

        Args:
            path: A path like `repo/src`. Leave empty to list the mounts.
        """
        return _files_list(table, path)

    def read_file(path: str, offset: int = 1, limit: int = 0) -> str:
        """Read a text file with line numbers and a content hash.

        Pass the hash back as `expected_hash` when editing, so a file that
        changed underneath you is reported instead of silently clobbered.

        Args:
            path: A path like `repo/src/main.py`.
            offset: First line to show, 1-based.
            limit: How many lines; 0 for the default page.
        """
        return _files_read(table, path, offset, limit)

    def search_files(pattern: str, path: str = "repo", glob: str = "") -> str:
        """Search file contents for a regular expression.

        Args:
            pattern: A Python regular expression.
            path: Mount or directory to search under, e.g. `repo/src` or `docs`.
            glob: Optional filename filter, e.g. `*.py`.
        """
        return _files_search(table, pattern, path, glob)

    def edit_file(
        path: str, old_text: str, new_text: str, expected_hash: str = ""
    ) -> str:
        """Replace an exact string that occurs exactly once in a file.

        Args:
            path: A path like `repo/src/main.py`.
            old_text: Text to replace. Must match once; include surrounding
                lines if it would otherwise be ambiguous.
            new_text: Replacement text.
            expected_hash: The hash from `read_file`, to catch stale edits.
        """
        return _changed(
            table, path, _files_edit, path, old_text, new_text, expected_hash
        )

    def write_file(path: str, content: str, expected_hash: str = "") -> str:
        """Create or overwrite a file.

        Args:
            path: A path like `repo/notes.md`.
            content: The complete new contents.
            expected_hash: The hash from `read_file` when overwriting.
        """
        return _changed(table, path, _files_write, path, content, expected_hash)

    for tool in (list_files, read_file, search_files, edit_file, write_file):
        tool.__doc__ = f"{tool.__doc__}\nMounts: {names}."

    return [edit_file, list_files, read_file, search_files, write_file]
