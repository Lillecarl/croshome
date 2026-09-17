#! /usr/bin/env python3
"""Report (and on --apply, fix) permission deviations inside a home directory.

The standard this audits against, and why:

NixOS creates homes with homeMode 0700 (users-groups.nix), and every tool
that manages private material -- ssh-keygen, gpg, kubectl -- enforces
0600/0700 on its own. On this machine the story is stricter still: every
local account shares the group `users`, so ANY group bit on a file exposes
it to every colleague, and the home directory is the only thing that keeps
them out. A future `chmod 755 ~` would silently turn every group-readable
file into a colleague-readable one.

So the standard is: no group or other access anywhere under the home. The
fix strips exactly those bits and leaves the owner's own bits alone -- a
644 file becomes 600, a 755 script becomes 700, a deliberately read-only
444 file becomes 400 instead of being handed owner-write. Executability is
preserved, not decided.

set-id and sticky directories, files owned by other users, sockets, fifos
and devices are never touched: they are reported as kept and are decisions
for a person. Symlinks are ignored (their mode is not real).

Dry-run by default: nothing changes without --apply. Exits 0 when
everything was fixed or deliberately kept, 1 when anything was left over,
2 on bad usage.
"""

import argparse
import os
import stat
import sys

HOME = "/home/lillecarl"

STRIP = stat.S_IRWXG | stat.S_IRWXO
EXAMPLES_WANTED = 15


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Audit (and fix) permissions inside the home directory.",
    )
    parser.add_argument("home", nargs="?", default=HOME, help="home to audit (default: %(default)s)")
    parser.add_argument("--apply", action="store_true", help="chmod; without this only report")
    parser.add_argument("--report", metavar="FILE", help="write every deviation and its verdict to FILE")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.home):
        parser.error(f"not a directory: {args.home}")
    return args


class Report:
    def __init__(self, path):
        self.fd = open(path, "w") if path else None
        self.classes = {}
        self.examples = {}
        self.errors = []

    def record(self, verdict, path):
        self.classes[verdict] = self.classes.get(verdict, 0) + 1
        bucket = self.examples.setdefault(verdict, [])
        if len(bucket) < EXAMPLES_WANTED:
            bucket.append(path)
        if self.fd:
            self.fd.write(f"{verdict}  {path}\n")

    def close(self):
        if self.fd:
            self.fd.close()


def skip_reason(st, uid):
    if st.st_uid != uid:
        return "kept: other owner"
    if st.st_mode & (stat.S_ISUID | stat.S_ISGID):
        return "kept: set-id"
    if stat.S_ISDIR(st.st_mode) and (st.st_mode & stat.S_ISVTX):
        return "kept: sticky dir"
    return None


def chmod_fd(path, st, new_mode):
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
    fixed = 0

    def scan_dir(top):
        try:
            with os.scandir(top) as it:
                return list(it)
        except OSError as err:
            report.errors.append(str(err))
            return []

    stack = [args.home]
    while stack:
        for entry in scan_dir(stack.pop()):
            path = entry.path
            try:
                if entry.is_symlink():
                    continue
                st = entry.stat(follow_symlinks=False)
            except OSError as err:
                report.errors.append(str(err))
                continue
            if not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
                continue
            if stat.S_ISDIR(st.st_mode):
                stack.append(path)

            if not st.st_mode & STRIP:
                continue
            reason = skip_reason(st, uid)
            if reason:
                report.record(reason, path)
                continue
            target = st.st_mode & ~STRIP
            verdict = f"{oct(stat.S_IMODE(st.st_mode))} -> {oct(stat.S_IMODE(target))}"
            report.record(verdict, path)
            if args.apply:
                try:
                    chmod_fd(path, st, target)
                    after = os.lstat(path)
                    if stat.S_IMODE(after.st_mode) != stat.S_IMODE(target):
                        raise OSError(f"{path}: bits survived the chmod")
                    fixed += 1
                except OSError as err:
                    report.errors.append(str(err))
                    report.record("error", path)
    report.close()

    for verdict, count in sorted(report.classes.items(), key=lambda kv: -kv[1]):
        print(f"{count:8d}  {verdict}")
        for p in report.examples.get(verdict, []):
            print(f"           {p}")
    if report.errors:
        print(f"\n{len(report.errors)} error(s):", file=sys.stderr)
        for err in report.errors[:EXAMPLES_WANTED]:
            print(f"  {err}", file=sys.stderr)

    if not args.apply:
        print("\ndry run: nothing changed (pass --apply to fix)")
        return 0
    print(f"\napplied: {fixed} path(s) fixed")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
