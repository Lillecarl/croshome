#! /usr/bin/env python3
"""Strip the group/other write bits the pymux umask bug left behind.

pymux's daemonize kept umask 0 on its whole process tree (Lillecarl/pymux#398),
so files its panes created came out 0666 and directories 0777 instead of the
0644 and 0755 the login umask asks for. The bug's damage is exactly the group
and other write bits: read bits were never inflated. Clearing g+w and o+w
therefore restores the mode the creating program meant, and touches nothing
else.

Dry-run by default. Pass --apply to change anything; pass --report FILE to get
every path with write bits written down with its verdict. The roots themselves
are never modified, only their contents. Exits 0 when every writable-by-others
path was either fixed or deliberately skipped, 1 when anything was left over,
2 on bad usage.

Deliberately left alone, and reported as skips:
  - symlinks (chmod must never travel through one)
  - setuid or setgid entries: those are shared-by-design, the write bits are
    part of that design
  - directories with the sticky bit set alongside o+w (/tmp and friends): the
    world-writability is the design, not debris
  - anything not owned by the invoking user, including whole directory
    subtrees that user cannot read
  - sockets, fifos and devices: recreated all the time, not file debris
"""

import argparse
import errno
import os
import stat
import sys
from collections import Counter

STRIP = stat.S_IWGRP | stat.S_IWOTH
EXAMPLES_WANTED = 15


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Clear the g+w and o+w bits left by the pymux umask bug.",
    )
    parser.add_argument(
        "roots",
        nargs="*",
        default=["/home/lillecarl", "/tmp", "/var/tmp"],
        help="trees to walk (default: %(default)s)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="clear the bits; without this nothing is changed",
    )
    parser.add_argument(
        "--report",
        metavar="FILE",
        help="write every considered path and its verdict to FILE",
    )
    args = parser.parse_args(argv)
    for root in args.roots:
        if not os.path.isdir(root):
            parser.error(f"not a directory: {root}")
    return args


class Report:
    def __init__(self, path):
        self.fd = open(path, "w") if path else None

    def line(self, text):
        if self.fd:
            self.fd.write(text + "\n")

    def close(self):
        if self.fd:
            self.fd.close()


def changed_mode(st):
    """The verdict line for one fixable entry, or None if its bits are fine."""
    mode = st.st_mode
    if stat.S_IMODE(mode) & STRIP == 0:
        return None
    return f"{stat.filemode(mode)} -> {stat.filemode(mode & ~STRIP)}"


def skip_reason(st, uid):
    """Why this entry must not be touched even though it carries write bits."""
    if st.st_uid != uid:
        return "kept: other owner"
    if stat.S_ISDIR(st.st_mode) and (st.st_mode & stat.S_ISVTX) and (st.st_mode & stat.S_IWOTH):
        return "kept: shared-temp dir"
    if st.st_mode & (stat.S_ISUID | stat.S_ISGID):
        return "kept: set-id"
    return None


def chmod_fd(path, st, new_mode):
    """fchmod through an O_NOFOLLOW fd, so a swapped-in symlink is refused."""
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if stat.S_ISDIR(st.st_mode):
        flags |= os.O_DIRECTORY
    fd = os.open(path, flags)
    try:
        after = os.fstat(fd)
        if (after.st_ino, after.st_dev) != (st.st_ino, st.st_dev) or after.st_mode != st.st_mode:
            raise OSError(f"{path}: changed between scan and fix")
        os.fchmod(fd, new_mode)
    finally:
        os.close(fd)


def main(argv):
    args = parse_args(argv)
    uid = os.getuid()
    report = Report(args.report)

    classes = Counter()
    examples = {}
    errors = []
    fixed = 0

    def record(verdict, path):
        classes[verdict] += 1
        if len(examples.get(verdict, [])) < EXAMPLES_WANTED:
            examples.setdefault(verdict, []).append(path)

    def scan_dir(top):
        try:
            with os.scandir(top) as it:
                return list(it)
        except OSError as err:
            if err.errno in (errno.EACCES, errno.EPERM):
                record("unreadable: other owner", top)
            else:
                errors.append(str(err))
            return []

    stack = list(args.roots)
    while stack:
        for entry in scan_dir(stack.pop()):
            path = entry.path
            try:
                if entry.is_symlink():
                    record("skipped: symlink", path)
                    continue
                st = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
                    record("skipped: not a file or directory", path)
                    continue
            except OSError as err:
                errors.append(str(err))
                continue

            # Descend before the bit checks: a directory the walk must enter
            # is usually clean itself, and the push must not hang on that.
            if stat.S_ISDIR(st.st_mode):
                stack.append(path)

            verdict = changed_mode(st)
            if verdict is None:
                continue
            reason = skip_reason(st, uid)
            if reason:
                record(reason, path)
                report.line(f"{reason}  {path}")
            else:
                record(verdict, path)
                report.line(f"{verdict}  {path}")
                if args.apply:
                    try:
                        chmod_fd(path, st, stat.S_IMODE(st.st_mode) & ~STRIP)
                        after = os.lstat(path)
                        if stat.S_IMODE(after.st_mode) & STRIP:
                            raise OSError(f"{path}: write bits survived the chmod")
                        fixed += 1
                    except OSError as err:
                        errors.append(str(err))
                        record("error", path)
    report.close()

    for verdict, count in sorted(classes.items(), key=lambda kv: -kv[1]):
        print(f"{count:8d}  {verdict}")
        for path in examples.get(verdict, []):
            print(f"           {path}")

    if errors:
        print(f"\n{len(errors)} error(s):", file=sys.stderr)
        for err in errors[:EXAMPLES_WANTED]:
            print(f"  {err}", file=sys.stderr)
        if len(errors) > EXAMPLES_WANTED:
            print(f"  ... and {len(errors) - EXAMPLES_WANTED} more", file=sys.stderr)

    if not args.apply:
        print("\ndry run: nothing changed (pass --apply to fix)")
        return 0
    print(f"\napplied: {fixed} path(s) fixed")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
