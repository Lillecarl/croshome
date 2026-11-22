"""pyjj workflow `land`: put this workspace's work on top of trunk, and
move trunk to it.

    pyjj wf land                # trunk is `main`
    pyjj wf land --onto trunk

What an agent does after each finished piece when several workspaces
share one repository. The rebase picks up what the other workspaces
landed meanwhile, and the bookmark move publishes this one's work to
them. Run it with `@` empty, that is, after `pyjj commit`. With nothing
to land, it only moves `@` onto trunk: how a workspace catches up.

It refuses, and writes nothing, when

- `@` holds changes (commit them first, or trunk would point at a
  commit still being edited),
- a commit to land has no description,
- the rebase would rewrite a commit another workspace's `@` builds on,
- the rebase leaves a commit in conflict.

Generated commits. Some repositories commit a file computed from the
commit under it, such as a lock naming its parent's hash. Rebasing one
is wrong even when it applies cleanly, and two workspaces' copies
conflict. Two repo config keys make `land` regenerate them instead:

    pyjj.land.generated   revset: the commits to drop before the rebase
    pyjj.land.generate    command: run after the rebase, in the
                          workspace root, to commit them again on top

With both set, `land` drops the generated commits from the stack,
rebases the rest, runs the command, then moves trunk. The bookmark
moves in a second operation, so a failing command leaves the work
rebased and trunk where it was; running `land` again starts over.

Landings in one repository are serialised by a lock file in the shared
repo directory, so two workspaces landing at once take turns instead of
leaving trunk conflicted. Trunk only moves forward. Only the local
bookmark moves; pushing stays a separate step.
"""

from __future__ import annotations

import contextlib
import fcntl
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

import pyjj

if TYPE_CHECKING:
    import argparse
    from collections.abc import Iterator

# Another workspace may land between the rebase and the bookmark move
# only from outside the lock (a second clone, a hand-moved bookmark).
ATTEMPTS = 3


class Land(pyjj.Workflow):
    name = "land"
    help = "Rebase this workspace's work onto trunk, then move trunk to it"

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--onto",
            default="main",
            metavar="BOOKMARK",
            help="The trunk bookmark to rebase onto and move (default: main)",
        )

    def run(self, repo: pyjj.Repo, args: argparse.Namespace) -> int:
        generated = repo.settings.get_string("pyjj.land.generated")
        generate = repo.settings.get_string("pyjj.land.generate")
        if bool(generated) != bool(generate):
            return _fail(
                "Set both pyjj.land.generated and pyjj.land.generate, or neither."
            )
        with _serialised(Path(repo.workspace.repo_path)):
            if not generate:
                return _land_plain(repo, args.onto)
            for _ in range(ATTEMPTS):
                result = _land_generated(repo, args.onto, generated, generate)
                if result is not None:
                    return result
            return _fail(f"{args.onto} kept moving; run land again.")


def _land_plain(repo: pyjj.Repo, onto: str) -> int:
    trunk = _quote(onto)
    plan = _plan(repo, onto, "none()")
    if isinstance(plan, int):
        return plan
    stack, rewrites = plan
    if not stack and not rewrites:
        print(f"Nothing to land: @ is already on {onto}.")
        return 0
    try:
        with repo.atomic(f"land onto {onto}") as block:
            if rewrites:
                _rebase(block, repo, trunk)
            head = block.bookmark(onto, "@-") if stack else None
    except pyjj.ConflictError as e:
        return _conflict(onto, e)
    if head is None:
        print(f"Nothing to land; @ is now on {onto}.")
    else:
        print(f"Landed {_count(stack)}; {onto} is now at {_short(head)}.")
    return 0


def _land_generated(
    repo: pyjj.Repo, onto: str, generated: str, generate: str
) -> int | None:
    """One pass. None: trunk moved while the command ran; go again."""
    trunk = _quote(onto)
    plan = _plan(repo, onto, generated)
    if isinstance(plan, int):
        return plan
    _stack, rewrites = plan
    stale = repo.revset(f"({trunk}..@-) & ({generated})")
    if rewrites or stale:
        try:
            with repo.atomic(f"land onto {onto}: rebase") as block:
                if stale:
                    block.abandon(stale)
                _rebase(block, repo, trunk)
        except pyjj.ConflictError as e:
            return _conflict(onto, e)
    done = subprocess.run(
        shlex.split(generate), cwd=repo.root, stdout=sys.stderr, check=False
    )
    if done.returncode != 0:
        return _fail(
            f"`{generate}` exited {done.returncode}. Your work is rebased "
            f"onto {onto}, and {onto} has not moved. Fix it and land again."
        )
    repo.reload().snapshot()
    if not repo.revset("@ & empty()"):
        return _fail(f"`{generate}` left changes in @; commit or drop them, then land.")
    if repo.revset(f"{trunk} ~ ::@-"):
        return None
    stack = repo.revset(f"{trunk}..@-")
    if not stack:
        print(f"Nothing to land; @ is on {onto}.")
        return 0
    with repo.atomic(f"land onto {onto}") as block:
        head = block.bookmark(onto, "@-")
    print(f"Landed {_count(stack)}; {onto} is now at {_short(head)}.")
    return 0


def _plan(
    repo: pyjj.Repo, onto: str, generated: str
) -> tuple[list[pyjj.Commit], bool] | int:
    """The commits to land and whether the stack must move, or an exit code."""
    trunk = _quote(onto)
    repo.snapshot()
    if not repo.revset(f"bookmarks(exact:{trunk})"):
        return _fail(f"No such bookmark: {onto}")
    if not repo.revset("@ & empty()"):
        return _fail(
            "The working copy has changes. Commit them first "
            "(`pyjj commit -m ...`), then land."
        )
    if repo.revset(f"{trunk} & conflicts()"):
        return _fail(f"{onto} itself is conflicted; resolve it first.")
    stack = repo.revset(f"{trunk}..@-")
    for commit in repo.revset(f"({trunk}..@-) ~ ({generated})"):
        if not commit.description.strip():
            return _fail(
                f"Commit {_short(commit)} has no description; "
                "describe it before landing."
            )
    on_trunk = repo.revset(trunk)[0].id
    rewrites = any(
        root.parent_ids != [on_trunk] for root in repo.revset(f"roots({trunk}..@)")
    ) or bool(repo.revset(f"({trunk}..@-) & ({generated})"))
    # A rewrite under another workspace's `@` leaves it stale, and its
    # unsaved edits end up in a divergent orphan.
    shared = repo.revset(f"({trunk}..@-) & ::(working_copies() ~ @)")
    if rewrites and shared:
        return _fail(
            f"Commit {_short(shared[0])} is under another "
            "workspace's working copy; rebasing it would leave "
            "that workspace stale."
        )
    return stack, rewrites


def _rebase(block: pyjj.Atomic, repo: pyjj.Repo, trunk: str) -> None:
    """`jj rebase -b @ -d trunk`, asked of the block: an abandon earlier
    in it rewrote the roots. Every root moves, so a side branch merged
    into the stack comes along."""
    roots = block.transaction.revset(repo.settings, f"roots({trunk}..@)")
    block.rebase([r.hex() for r in roots], destination=trunk, whole_branch=True)


@contextlib.contextmanager
def _serialised(repo_path: Path) -> Iterator[None]:
    with (repo_path / "land.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Waiting for another land in this repository...", file=sys.stderr)
            fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _conflict(onto: str, error: pyjj.ConflictError) -> int:
    return _fail(
        f"Your work conflicts with {onto}: {', '.join(error.change_ids)} would "
        "be conflicted. Nothing was written. Rebase it yourself with "
        f"`pyjj rebase -b @ -d {shlex.quote(onto)}`, resolve the conflicts, then land."
    )


def _quote(name: str) -> str:
    """A bookmark name as a revset string literal."""
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _count(stack: list[pyjj.Commit]) -> str:
    return f"{len(stack)} commit{'' if len(stack) == 1 else 's'}"


def _short(commit: pyjj.Commit) -> str:
    first = commit.description.splitlines()[0] if commit.description else ""
    return f"{commit.change_id.reverse_hex()[:12]} {first}".rstrip()


def _fail(message: str) -> int:
    print(f"Error: {message}", file=sys.stderr)
    return 1
