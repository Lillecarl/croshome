#! /usr/bin/env python3
"""What can the other accounts on this machine read?

Colleagues hold unprivileged accounts here (see ./dynusers.nix). They are
trusted, and still should not be reading keys, tokens or histories. Replaces
the bash scan-access.sh, whose runtime wrapper added `set -o errexit` on top
of the script's own options, so find's "unreadable directory" and grep's
"no matches" -- both exit 1, both expected -- killed the scan halfway. Exits
1 on any finding, so a timer can nag later if one ever runs it.

The scans, in order:

  1. The home directories themselves: other-readable, other-traversable, or
     shared-group readable. 0700 is the shape that keeps everything under a
     home out of reach; the scans below then only matter for homes that are
     open.
  2. Sensitive files other users can reach, by name and directory. A file
     whose bits say readable but whose ancestor directories lock the path is
     reported as latent, not as a finding: nothing is reachable through it
     today, and the line is there so a future chmod of a home directory does
     not silently turn it into a leak.
  3. Reachable files whose CONTENT looks like a secret.
  4. Files other users can write -- worse than a read, always a finding.
     /dev/shm is scanned here too; /run/user is not (systemd's own sockets
     sit behind a 0700 directory, by design).
  5. The repository: tracked files checked for secret-shaped content, every
     .age file checked to really be ciphertext.
  6. Paths writable by others whose owner is somebody else. sudo keeps the
     caller's umask, so a root shell opened from a pane of the broken pymux
     (umask 0) wrote root-owned 0666 files; nothing running as a user can
     fix those, so they are recorded for whoever has the right to chmod
     them.

Find history is not scanned: this repository is public, and a scan that walks
every historical blob is a different tool.
"""

import argparse
import grp
import os
import pwd
import re
import stat
import subprocess
import sys

HOME_ROOT = "/home"
DEFAULT_REPO = "/home/lillecarl/Code/croshome"

# Checkouts, stores and build trees: unreadably large, and the repository
# scan covers the checkout that matters. find(1) pruned these by name, files
# included; the walk below does the same.
PRUNE_NAMES = {
    ".git", ".jj", "node_modules", ".cache", ".npm", ".cargo", ".rustup",
    "target", ".nix-defexpr", "result",
}

SECRET_SHAPES = re.compile(
    r"BEGIN [A-Z ]*PRIVATE KEY"
    r"|AGE-SECRET-KEY-[A-Z0-9]{20,}"
    r"|ghp_[A-Za-z0-9]{20,}"
    r"|gho_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|sk-ant-[A-Za-z0-9-]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|xox[abp]-[A-Za-z0-9-]{10,}"
)

# -iname predicates from the bash find: case-insensitive name match.
SENSITIVE_INAME = re.compile(
    r"^(?:id_(?:rsa|ecdsa|ed25519|dsa)|.*\.pem|.*\.key|.*\.age"
    r"|\.env|\.env\..*|.*token.*|.*password.*|.*credential.*)$",
    re.IGNORECASE,
)
# -name predicates: case-sensitive.
SENSITIVE_NAME = {".git-credentials", ".netrc"}
# -path predicates.
SENSITIVE_PATH = (
    "/.ssh/", "/.gnupg/", "/.kube/", "/.docker/",
    "/.config/gh/", "/.config/cachix/",
    "/.config/opencode/", "/.config/codex/",
    "/.claude/", "/.gemini/",
)

# Public by design, or a throwaway fixture: the name is the match. The
# vm-test key pair unlocks a NixOS test VM that exists for the length of one
# test run.
PUBLIC_BY_NAME = re.compile(r"^(?:secrets\.nix|vm-test-ssh-unlock-.*)$")

KEEP_NAME = re.compile(r"^(?:.*authorized_keys|.*\.pub|.*known_hosts)$")


class Report:
    def __init__(self):
        self.findings = 0
        self.latent = []

    def note(self, text):
        print(text)

    def bad(self, text):
        self.findings += 1
        print(f"  FINDING: {text}")

    def latent_line(self, text):
        self.latent.append(text)

    def show_latent(self):
        if self.latent:
            for line in self.latent[:5]:
                print(f"  latent:  {line}")
            if len(self.latent) > 5:
                print(f"  latent:  +{len(self.latent) - 5} more")
            self.latent = []


def group_of(st):
    try:
        return grp.getgrgid(st.st_gid).gr_name
    except KeyError:
        return str(st.st_gid)


def others_can_read(st, group):
    return bool(st.st_mode & stat.S_IROTH) or (
        bool(st.st_mode & stat.S_IRGRP) and group == "users"
    )


def others_can_write(st, group):
    return bool(st.st_mode & stat.S_IWOTH) or (
        bool(st.st_mode & stat.S_IWGRP) and group == "users"
    )


def others_can_reach(path):
    """Can an account outside the owner's session traverse to this path?

    Reaching a known path needs search (x) on every DIRECTORY above it --
    the file's own bits are already the caller's predicate. The bash
    version this replaces checked the target file too, which made every
    non-executable file classify as unreachable; wrong for anything
    outside the 0700 home. Bit-based, like the stat(1) checks it replaces:
    the scanner runs as the owner, so os.access() would answer the wrong
    question.
    """
    p = os.path.dirname(os.path.abspath(path))
    while p != "/":
        try:
            st = os.stat(p)
        except OSError:
            return False
        group_x = bool(st.st_mode & stat.S_IXGRP) and group_of(st) == "users"
        if not (st.st_mode & stat.S_IXOTH) and not group_x:
            return False
        p = os.path.dirname(p)
    return True


def walk_files(root, want):
    """Yield (path, st) for every regular file under root that want() accepts.

    Mirrors the bash find's shape: pruned names never surface, one device
    only, unreadable directories pass by silently.
    """
    root_dev = os.stat(root).st_dev
    stack = [root]
    while stack:
        top = stack.pop()
        try:
            with os.scandir(top) as it:
                entries = list(it)
        except OSError:
            continue
        for entry in entries:
            path = entry.path
            name = entry.name
            try:
                if entry.is_symlink():
                    continue
                st = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if name in PRUNE_NAMES:
                continue
            if stat.S_ISDIR(st.st_mode):
                if st.st_dev == root_dev:
                    stack.append(path)
                continue
            if stat.S_ISREG(st.st_mode) and want(path, name, st):
                yield path, st


def is_sensitive(path, name):
    return (
        name in SENSITIVE_NAME
        or SENSITIVE_INAME.fullmatch(name) is not None
        or any(marker in path for marker in SENSITIVE_PATH)
    )


def scan_homes(report):
    report.note("== 1. home directories ==")
    try:
        entries = sorted(os.scandir(HOME_ROOT), key=lambda e: e.name)
    except OSError as err:
        report.bad(f"cannot list {HOME_ROOT}: {err}")
        return
    for entry in entries:
        if not entry.is_dir(follow_symlinks=False):
            continue
        try:
            st = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        group = group_of(st)
        other_r = bool(st.st_mode & stat.S_IROTH)
        group_r = bool(st.st_mode & stat.S_IRGRP)
        if other_r or (group_r and group == "users"):
            bits = stat.filemode(st.st_mode)
            report.bad(f"{entry.path} is mode {bits} -- others can list it (want 0700)")
    if report.findings == 0:
        report.note("  every home is closed to others")


# Where the read scans look. The home is where private material lives, but
# the umask bug also wrote 0666 files into the world-traversable scratch
# trees; stripped to 644, they are still other-readable, so those trees are
# scanned for sensitive names and secret-shaped content as well.
READ_SCAN_ROOTS = (HOME_ROOT, "/tmp", "/var/tmp")


def scan_sensitive(report):
    report.note("== 2. sensitive files reachable by others ==")
    found = False

    def want(path, name, st):
        return is_sensitive(path, name) and others_can_read(st, group_of(st))

    for root in READ_SCAN_ROOTS:
        for path, st in walk_files(root, want):
            found = True
            if KEEP_NAME.fullmatch(os.path.basename(path)):
                continue
            if others_can_reach(path):
                report.bad(f"readable by others: {path}")
            else:
                report.latent_line(f"bits say readable, the path does not: {path}")
    if not found:
        report.note("  none")
    report.show_latent()


def scan_content(report):
    report.note("== 3. reachable files whose content looks like a secret ==")

    def want(path, name, st):
        return st.st_size < 1024 * 1024 and others_can_read(st, group_of(st))

    found = False
    for root in READ_SCAN_ROOTS:
        for path, st in walk_files(root, want):
            try:
                with open(path, "rb") as fd:
                    data = fd.read()
            except OSError:
                continue
        if b"\0" in data[:8192]:
            continue
        if not SECRET_SHAPES.search(data.decode("utf-8", errors="replace")):
            continue
        found = True
        if others_can_reach(path):
            report.bad(f"secret-shaped content readable by others: {path}")
        else:
            report.latent_line(f"secret-shaped content, behind a closed path: {path}")
    if not found:
        report.note("  none")
    report.show_latent()


def scan_writable(report):
    report.note("== 4. files other users can write ==")

    def want(path, name, st):
        return others_can_write(st, group_of(st))

    found = False
    roots = [HOME_ROOT] + (["/dev/shm"] if os.path.isdir("/dev/shm") else [])
    for root in roots:
        for path, st in walk_files(root, want):
            found = True
            if others_can_reach(path):
                report.bad(f"writable by others: {path}")
            else:
                report.latent_line(f"writable if the path ever opens: {path}")
    if not found:
        report.note("  none")
    report.show_latent()


def scan_foreign_writable(report, uid):
    """Writable paths whose owner is somebody else, across the root fs.

    sudo keeps the caller's umask: a root shell from a umask-0 pane wrote
    root-owned 0666 files. Nothing running as a user can chmod those, so
    they are recorded, not fixed. The designed world-writable shapes (a
    sticky directory) are not findings; /nix, /proc, /sys, /dev and /run
    are pruned -- /run/user holds systemd's own sockets by design.
    """
    report.note("== 6. paths writable by others, owned by someone else ==")
    root_dev = os.stat("/").st_dev
    stack = ["/"]
    found = False

    def anomalous(path, st):
        group = group_of(st)
        if stat.S_ISDIR(st.st_mode):
            if st.st_mode & stat.S_ISVTX:
                return False
            if st.st_mode & (stat.S_ISUID | stat.S_ISGID):
                return False
        return bool(st.st_mode & stat.S_IWOTH) or (
            bool(st.st_mode & stat.S_IWGRP) and group == "users"
        )

    while stack:
        top = stack.pop()
        if top == "/nix":
            # The store: hundreds of thousands of root-owned entries, all
            # 0444 or 0555 by construction. Walking it costs minutes and
            # finds nothing, ever.
            continue
        try:
            with os.scandir(top) as it:
                entries = list(it)
        except OSError:
            continue
        for entry in entries:
            if entry.name in PRUNE_NAMES:
                continue
            path = entry.path
            try:
                if entry.is_symlink():
                    continue
                st = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if st.st_dev == root_dev:
                    stack.append(path)
                elif st.st_uid != uid and anomalous(path, st):
                    # A mount point rooted inside /: /dev/shm and friends.
                    found = True
                    report.bad(f"writable by others, owned by {owner_name(st)}: {path}")
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if st.st_uid != uid and anomalous(path, st):
                found = True
                report.bad(f"writable by others, owned by {owner_name(st)}: {path}")
    if not found:
        report.note("  none")


def owner_name(st):
    try:
        return pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        return str(st.st_uid)


def scan_repo(report, repo):
    report.note(f"== 5. repository: {repo} ==")
    if not os.path.isdir(os.path.join(repo, ".jj")) and not os.path.isdir(os.path.join(repo, ".git")):
        report.bad(f"no repository at {repo}")
        return
    proc = subprocess.run(
        ["jj", "--no-pager", "file", "list", "-r", "@"],
        cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        report.note("  could not list tracked files; skipping")
        return
    files = [f for f in proc.stdout.splitlines() if f]
    vanished = 0
    content_hits = []
    for rel in files:
        full = os.path.join(repo, rel)
        try:
            with open(full, "rb") as fd:
                data = fd.read()
        except OSError:
            vanished += 1
            continue
        head = data[:40]
        base = os.path.basename(rel)
        if rel.endswith(".age"):
            if not (head.startswith(b"-----BEGIN") or head.startswith(b"age-encryption.org")):
                report.bad(f"tracked .age file is not ciphertext: {rel}")
            continue
        if PUBLIC_BY_NAME.fullmatch(base):
            continue
        if re.fullmatch(r".*\.(?:key|pem|env|token)|.*secret.*", base):
            report.bad(f"tracked file looks like a plaintext secret: {rel}")
        if b"\0" in head:
            continue
        if SECRET_SHAPES.search(data.decode("utf-8", errors="replace")):
            content_hits.append(rel)
    if content_hits:
        for rel in content_hits:
            if not PUBLIC_BY_NAME.fullmatch(os.path.basename(rel)):
                report.bad(f"tracked file carries secret-shaped content: {rel}")
    else:
        report.note("  tracked files carry no secret-shaped content")
    if vanished:
        report.note(f"  {vanished} tracked file(s) changed while scanning; skipped")


def main(argv):
    parser = argparse.ArgumentParser(description="Access scan of /home and the repository.")
    parser.add_argument("repo", nargs="?", default=DEFAULT_REPO, help="repository to scan (default: %(default)s)")
    args = parser.parse_args(argv)

    report = Report()
    scan_homes(report)
    scan_sensitive(report)
    scan_content(report)
    scan_writable(report)
    scan_repo(report, args.repo)
    scan_foreign_writable(report, os.getuid())

    print()
    if report.findings:
        report.note(f"{report.findings} finding(s)")
        return 1
    report.note("clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
