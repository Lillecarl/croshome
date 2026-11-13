"""pyjj workflow `land`: put this workspace's work on top of trunk, and
move trunk to it.

    pyjj wf land                # trunk is `main`
    pyjj wf land --onto trunk

What an agent does after each finished piece when several workspaces
share one repository. The rebase picks up what the other workspaces
landed meanwhile, and the bookmark move publishes this one's work to
them. Run it with `@` empty, that is, after `pyjj commit`. With nothing
to land, it only moves `@` onto trunk: how a workspace catches up.

The rebase and the move are one transaction: both land or neither does.
It refuses, and writes nothing, when

- `@` holds changes (commit them first, or trunk would point at a
  commit still being edited),
- a commit to land has no description,
- the rebase would rewrite a commit another workspace's `@` builds on,
- the rebase leaves a commit in conflict.

Trunk only moves forward, so pyjj's fast-forward guard passes it. Only
the local bookmark moves; pushing stays a separate step.
"""

from __future__ import annotations

import sys
from typing import TYPE_CHECKING

import pyjj

if TYPE_CHECKING:
    import argparse


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
        trunk = _quote(args.onto)
        repo = repo.snapshot()
        # Checked before the block: a block that exits cleanly records an
        # operation even when it did nothing.
        if not repo.revset(f"bookmarks(exact:{trunk})"):
            return _fail(f"No such bookmark: {args.onto}")
        if not repo.revset("@ & empty()"):
            return _fail(
                "The working copy has changes. Commit them first "
                "(`pyjj commit -m ...`), then land."
            )
        stack = repo.revset(f"{trunk}..@-")
        # `jj rebase -b @ -d trunk`: every root of the branch moves, so a
        # side branch merged into the stack comes along. With an empty
        # stack the one root is `@`.
        roots = repo.revset(f"roots({trunk}..@)")
        on_trunk = repo.revset(trunk)[0].id
        rewrites = any(root.parent_ids != [on_trunk] for root in roots)
        if not stack:
            if rewrites:
                with repo.atomic(f"rebase @ onto {args.onto}") as block:
                    block.rebase("@", destination=trunk)
                print(f"Nothing to land; @ is now on {args.onto}.")
            else:
                print(f"Nothing to land: @ is already on {args.onto}.")
            return 0
        for commit in stack:
            if not commit.description.strip():
                return _fail(
                    f"Commit {_short(commit)} has no description; "
                    "describe it before landing."
                )
        # A rewrite under another workspace's `@` leaves it stale, and its
        # unsaved edits end up in a divergent orphan.
        shared = repo.revset(f"({trunk}..@-) & ::(working_copies() ~ @)")
        if rewrites and shared:
            return _fail(
                f"Commit {_short(shared[0])} is under another "
                "workspace's working copy; rebasing it would leave "
                "that workspace stale."
            )
        with repo.atomic(f"land onto {args.onto}") as block:
            if rewrites:
                block.rebase(roots, destination=trunk, whole_branch=True)
            head = block.bookmark(args.onto, "@-")
        print(
            f"Landed {len(stack)} commit{'' if len(stack) == 1 else 's'}; "
            f"{args.onto} is now at {_short(head)}."
        )
        return 0


def _quote(name: str) -> str:
    """A bookmark name as a revset string literal."""
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _short(commit: pyjj.Commit) -> str:
    first = commit.description.splitlines()[0] if commit.description else ""
    return f"{commit.change_id.reverse_hex()[:12]} {first}".rstrip()


def _fail(message: str) -> int:
    print(f"Error: {message}", file=sys.stderr)
    return 1
