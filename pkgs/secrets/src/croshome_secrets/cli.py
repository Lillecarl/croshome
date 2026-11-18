"""`secrets`: croshome's front end to sops. See secrets/README.md.

Sync on purpose: every command runs sops, age or ssh against the terminal
(passphrase prompts, $EDITOR) and exits.

stdout carries only results: a value, or JSON. Progress goes to stderr with
--verbose; errors always do.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Final

from . import keys as k
from . import keystore

if TYPE_CHECKING:
    from collections.abc import Sequence

AGE_SECRET_PREFIX: Final = "AGE-SECRET-KEY-"
HOST_KEY: Final = "/etc/ssh/ssh_host_ed25519_key"


class Fail(Exception):
    """A user-facing error: printed as one line, exit 1."""


@dataclass(frozen=True, slots=True)
class Repo:
    root: Path

    @property
    def sops_dir(self) -> Path:
        return self.root / "secrets" / "sops"

    @property
    def keys_file(self) -> Path:
        return self.sops_dir / "keys.json"

    @property
    def identity(self) -> Path:
        return self.root / "secrets" / "identity.age"

    def keys(self) -> k.Keys:
        return k.Keys.parse(self.keys_file.read_text())

    def write_keys(self, keys: k.Keys) -> None:
        tmp = self.keys_file.with_suffix(".tmp")
        tmp.write_text(keys.dump())
        tmp.replace(self.keys_file)


def find_repo(start: Path, env: dict[str, str]) -> Repo:
    for d in (start, *start.parents):
        if (d / "secrets" / "sops" / "keys.json").is_file():
            return Repo(d)
    fallback = Path(env.get("CROSHOME", Path.home() / "Code" / "croshome"))
    if (fallback / "secrets" / "sops" / "keys.json").is_file():
        return Repo(fallback)
    raise Fail(f"no croshome checkout above {start} or at {fallback}; set CROSHOME")


def tpm_identity_path(env: dict[str, str]) -> Path:
    config = Path(env.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return config / "sops" / "age" / "tpm.txt"


def has_tty() -> bool:
    try:
        with Path("/dev/tty").open():
            return True
    except OSError:
        return False


def run(cmd: Sequence[str], *, stdin: str | None = None) -> str:
    done = subprocess.run(
        list(cmd), input=stdin, capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        raise Fail(f"{cmd[0]} failed: {done.stderr.strip()}")
    return done.stdout


@dataclass(slots=True)
class Session:
    repo: Repo
    store: keystore.Keystore
    tpm: Path | None
    verbose: bool

    def say(self, msg: str) -> None:
        if self.verbose:
            print(f"secrets: {msg}", file=sys.stderr)

    def unlock(self) -> None:
        if self.store.get() is not None:
            return
        if not has_tty():
            raise Fail(
                "locked, and no terminal to ask for the passphrase. Run 'secrets unlock' in a terminal."
            )
        print(
            f"secrets: decrypting {self.repo.identity} (scrypt, a few seconds)",
            file=sys.stderr,
        )
        # stderr stays on the terminal: age asks for the passphrase on /dev/tty.
        done = subprocess.run(
            ["age", "--decrypt", str(self.repo.identity)],
            stdout=subprocess.PIPE,
            text=True,
            check=False,
        )
        if done.returncode != 0:
            raise Fail("could not decrypt the master key")
        secret = [
            line
            for line in done.stdout.splitlines()
            if line.startswith(AGE_SECRET_PREFIX)
        ]
        if len(secret) != 1:
            raise Fail(
                f"{self.repo.identity} holds {len(secret)} secret keys, expected 1"
            )
        self.store.put(secret[0] + "\n")

    def sops_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["SOPS_AGE_KEY_CMD"] = f"{Path(sys.argv[0]).resolve()} key"
        if self.tpm is not None:
            env["SOPS_AGE_KEY_FILE"] = str(self.tpm)
        return env

    def sops(
        self, *args: str, stdin: str | None = None, capture: bool = False
    ) -> subprocess.CompletedProcess[str]:
        # Unlock first: sops swallows the key command's stderr, so a locked
        # keystore would surface only as "no master key was able to decrypt".
        if self.tpm is None:
            self.unlock()
        return subprocess.run(
            ["sops", *args],
            cwd=self.repo.sops_dir,
            env=self.sops_env(),
            input=stdin,
            text=True,
            capture_output=capture,
            check=False,
        )

    def sops_ok(self, *args: str, stdin: str | None = None) -> str:
        done = self.sops(*args, stdin=stdin, capture=True)
        if done.returncode != 0:
            raise Fail(f"sops {args[0]} failed:\n{done.stderr.strip()}")
        return done.stdout

    def get(self, file: str, key: str) -> str:
        return self.sops_ok("decrypt", "--extract", k.sops_index(key), file)

    def set(self, file: str, key: str, value: str) -> None:
        target = self.repo.sops_dir / file
        if target.exists():
            self.sops_ok(
                "set", "--value-stdin", file, k.sops_index(key), stdin=json.dumps(value)
            )
            return
        self.create(file, json.dumps(k.nested(key, value)), input_type="json")

    def create(self, file: str, plain: str, *, input_type: str = "yaml") -> None:
        target = self.repo.sops_dir / file
        if target.exists():
            raise Fail(f"{file} exists; use set or edit")
        # Encrypting needs only public keys, so this never unlocks.
        done = subprocess.run(
            ["sops", "encrypt", "--input-type", input_type, "--output-type", "yaml",
             "--filename-override", file, "/dev/stdin"],
            cwd=self.repo.sops_dir, input=plain, capture_output=True, text=True, check=False,
        )  # fmt: skip
        if done.returncode != 0:
            raise Fail(f"sops encrypt failed:\n{done.stderr.strip()}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(done.stdout)

    def sync(self) -> list[str]:
        config = k.sops_config(self.repo.keys())
        (self.repo.sops_dir / ".sops.yaml").write_text(
            json.dumps(config, indent=2) + "\n"
        )
        self.say("wrote .sops.yaml")
        files = sorted(
            str(p.relative_to(self.repo.sops_dir))
            for p in self.repo.sops_dir.rglob("*.yaml")
            if p.name != ".sops.yaml"
        )
        for f in files:
            self.sops_ok("updatekeys", "--yes", f)
            self.say(f"re-encrypted {f}")
        return files


def cmd_host_add(s: Session, a: argparse.Namespace) -> object:
    """Returns the JSON result. `object`: printed as JSON, any shape."""
    result: dict[str, str] = {"host": a.name}
    if a.ssh:
        pub = run(["ssh", "-o", "BatchMode=yes", a.ssh, "cat", f"{HOST_KEY}.pub"])
        result["ssh_fingerprint"] = run(["ssh-keygen", "-lf", "-"], stdin=pub).split()[
            1
        ]
        recipient = run(["ssh-to-age"], stdin=pub).strip()
    elif a.generate:
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "key"
            run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    f"root@{a.name}",
                    "-f",
                    str(key),
                ]
            )
            s.set("admin.yaml", f"host-keys.{a.name}.private", key.read_text())
            pub = key.with_suffix(".pub").read_text()
            s.set("admin.yaml", f"host-keys.{a.name}.public", pub)
        result["ssh_fingerprint"] = run(["ssh-keygen", "-lf", "-"], stdin=pub).split()[
            1
        ]
        recipient = run(["ssh-to-age"], stdin=pub).strip()
    else:
        recipient = a.recipient
    if not recipient.startswith("age1"):
        raise Fail(f"not an age recipient: {recipient!r}")
    s.repo.write_keys(k.with_host(s.repo.keys(), a.name, recipient, a.file))
    result["recipient"] = recipient
    s.sync()
    return result


def cmd_host_rm(s: Session, name: str) -> object:
    """Unregister NAME. Its own file goes too: no rule would match it after."""
    s.repo.write_keys(k.without_host(s.repo.keys(), name))
    own = s.repo.sops_dir / "hosts" / f"{name}.yaml"
    removed = [str(own.relative_to(s.repo.sops_dir))] if own.exists() else []
    own.unlink(missing_ok=True)
    held = s.sops(
        "decrypt",
        "--extract",
        k.sops_index(f"host-keys.{name}"),
        "admin.yaml",
        capture=True,
    )
    if held.returncode == 0:
        s.sops_ok("unset", "admin.yaml", k.sops_index(f"host-keys.{name}"))
        removed.append(f"admin.yaml:host-keys.{name}")
    return {"removed": removed, "synced": s.sync()}


def cmd_install_files(s: Session, a: argparse.Namespace) -> object:
    ssh_dir = Path(a.dir) / "etc" / "ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    private = ssh_dir / "ssh_host_ed25519_key"
    private.touch(mode=0o600)
    private.write_text(s.get("admin.yaml", f"host-keys.{a.name}.private"))
    public = ssh_dir / "ssh_host_ed25519_key.pub"
    public.write_text(s.get("admin.yaml", f"host-keys.{a.name}.public"))
    public.chmod(0o644)
    return {"host": a.name, "extra_files": str(Path(a.dir).resolve())}


def cmd_tpm_enroll(s: Session, _: argparse.Namespace) -> object:
    target = tpm_identity_path(dict(os.environ))
    if target.exists():
        raise Fail(f"{target} exists")
    if not Path("/dev/tpmrm0").exists():
        raise Fail("no /dev/tpmrm0 on this machine")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run(["age-plugin-tpm", "--generate", "-o", str(target)])
    target.chmod(0o600)
    recipient = run(["age-plugin-tpm", "-y", str(target)]).strip()
    name = f"{os.uname().nodename.split('.')[0]}-tpm"
    s.repo.write_keys(k.with_admin(s.repo.keys(), name, recipient))
    # The new identity opens nothing until this sync re-encrypts to it.
    s.tpm = None
    s.sync()
    return {"admin": name, "recipient": recipient}


def cmd_status(s: Session, _: argparse.Namespace) -> object:
    keys = s.repo.keys()
    tpm = run(["age-plugin-tpm", "-y", str(s.tpm)]).strip() if s.tpm else None
    return {
        "repo": str(s.repo.root),
        "unlocked": s.store.get() is not None,
        "tpm_recipient": tpm,
        "admins": sorted(keys.admins),
        "hosts": sorted(keys.hosts),
    }


def cmd_key(store: keystore.Keystore, env: dict[str, str], verbose: bool) -> None:
    """For SOPS_AGE_KEY_CMD, so it must work outside a checkout while unlocked."""
    held = store.get()
    if held is None:
        repo = find_repo(Path.cwd(), env)
        if wrong_recipient(repo, env):
            return
        Session(repo, store, None, verbose).unlock()
        held = store.get() or ""
    sys.stdout.write(held)


def wrong_recipient(repo: Repo, env: dict[str, str]) -> bool:
    # sops calls the key command once per recipient stanza. Answer only for
    # the master, so a stanza a TPM identity opens never asks for a passphrase.
    asked = env.get("SOPS_AGE_RECIPIENT")
    return bool(asked) and asked != repo.keys().admins[k.MASTER]


def stdin_value() -> str:
    if sys.stdin.isatty():
        raise Fail("the value comes from stdin")
    value = sys.stdin.read()
    if not value:
        raise Fail("stdin was empty; refusing to store an empty value")
    return value


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="secrets",
        description="croshome's front end to sops; FILE is relative to secrets/sops, KEY is dotted (aid.token)",
    )
    p.add_argument("-v", "--verbose", action="store_true", help="progress on stderr")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("edit", help="open FILE in $EDITOR").add_argument("file")
    g = sub.add_parser("get", help="print one value")
    g.add_argument("file")
    g.add_argument("key")
    st = sub.add_parser(
        "set", help="write one value from stdin; creates FILE if missing"
    )
    st.add_argument("file")
    st.add_argument("key")
    sub.add_parser(
        "create", help="new FILE from plaintext YAML on stdin; needs no unlock"
    ).add_argument("file")
    sub.add_parser(
        "sync", help="rewrite .sops.yaml from keys.json and re-encrypt every file"
    )

    host = sub.add_parser("host", help="register hosts").add_subparsers(
        dest="host_cmd", required=True
    )
    host.add_parser("list")
    add = host.add_parser("add", help="register a host and sync")
    add.add_argument("name")
    how = add.add_mutually_exclusive_group(required=True)
    how.add_argument("--ssh", metavar="TARGET", help="read the host key over ssh")
    how.add_argument(
        "--generate",
        action="store_true",
        help="make a host key for a fresh install; kept in admin.yaml",
    )
    how.add_argument("--recipient", metavar="AGE1...")
    add.add_argument(
        "--file",
        action="append",
        default=[],
        help="a shared file this host reads; repeatable",
    )
    inst = host.add_parser(
        "install-files", help="write a --generate'd host key under DIR/etc/ssh"
    )
    inst.add_argument("name")
    inst.add_argument("dir")
    host.add_parser("rm", help="unregister a host and sync").add_argument("name")

    admin = sub.add_parser("admin", help="keys that open every file").add_subparsers(
        dest="admin_cmd", required=True
    )
    aa = admin.add_parser("add")
    aa.add_argument("name")
    aa.add_argument("recipient")
    admin.add_parser("rm").add_argument("name")
    sub.add_parser(
        "tpm-enroll", help="make a TPM admin key on this machine, add it, sync"
    )

    sub.add_parser("unlock", help="put the master key in the keystore")
    sub.add_parser("lock", help="remove it")
    sub.add_parser("status", help="JSON: keystore, TPM, admins, hosts")
    sub.add_parser("key", help="print the master key; for SOPS_AGE_KEY_CMD")
    sp = sub.add_parser("sops", help="run sops in secrets/sops with the keys set up")
    sp.add_argument("args", nargs=argparse.REMAINDER)
    return p


def dispatch(s: Session, a: argparse.Namespace) -> object:
    """The command's result, printed as JSON; None prints nothing."""
    match a.cmd:
        case "edit":
            raise SystemExit(s.sops("edit", a.file).returncode)
        case "get":
            sys.stdout.write(s.get(a.file, a.key))
        case "set":
            s.set(a.file, a.key, stdin_value())
        case "create":
            s.create(a.file, stdin_value())
        case "sync":
            return {"synced": s.sync()}
        case "host":
            match a.host_cmd:
                case "list":
                    return s.repo.keys().hosts
                case "add":
                    return cmd_host_add(s, a)
                case "install-files":
                    return cmd_install_files(s, a)
                case "rm":
                    return cmd_host_rm(s, a.name)
        case "admin":
            if a.admin_cmd == "add":
                s.repo.write_keys(k.with_admin(s.repo.keys(), a.name, a.recipient))
            else:
                s.repo.write_keys(k.without_admin(s.repo.keys(), a.name))
            return {"synced": s.sync()}
        case "tpm-enroll":
            return cmd_tpm_enroll(s, a)
        case "unlock":
            s.unlock()
        case "lock":
            s.store.delete()
        case "status":
            return cmd_status(s, a)
        case "sops":
            raise SystemExit(s.sops(*a.args).returncode)
    return None


def main(argv: Sequence[str] | None = None) -> None:
    a = parser().parse_args(argv)
    env = dict(os.environ)
    try:
        if a.cmd == "key":
            cmd_key(keystore.default(), env, a.verbose)
            return
        tpm = tpm_identity_path(env)
        s = Session(
            repo=find_repo(Path.cwd(), env),
            store=keystore.default(),
            tpm=tpm if tpm.is_file() else None,
            verbose=a.verbose,
        )
        result = dispatch(s, a)
    except (Fail, ValueError) as e:
        print(f"secrets: {e}", file=sys.stderr)
        raise SystemExit(1) from None
    except FileNotFoundError as e:
        print(f"secrets: {e.filename} is not installed", file=sys.stderr)
        raise SystemExit(1) from None
    if result is not None:
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
