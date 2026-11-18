"""Where the decrypted master key waits between commands.

Linux: the user keyring, until reboot. macOS: the login Keychain, until
`secrets lock` (it survives a reboot).
"""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Final, Protocol

NAME: Final = "croshome-age"


class Keystore(Protocol):
    def get(self) -> str | None: ...
    def put(self, key: str) -> None: ...
    def delete(self) -> None: ...


class KernelKeyring:
    def _id(self) -> str | None:
        found = subprocess.run(
            ["keyctl", "search", "@u", "user", NAME],
            capture_output=True,
            text=True,
            check=False,
        )
        return found.stdout.strip() if found.returncode == 0 else None

    def get(self) -> str | None:
        ident = self._id()
        if ident is None:
            return None
        return subprocess.run(
            ["keyctl", "pipe", ident], capture_output=True, text=True, check=True
        ).stdout

    def put(self, key: str) -> None:
        # A login shell's session keyring does not link @u, so a key added from
        # it is not possessed there: it gets only the default user perm, view,
        # and setperm is refused. Linking @u into a throwaway session gives
        # possession for the setperm. User then gets view, read and search, so
        # any process of this uid reads it, a systemd user unit included.
        script = f'keyctl link @u @s && keyctl setperm "$(keyctl padd user {NAME} @u)" 0x3f0b0000'
        subprocess.run(
            ["keyctl", "session", "-", "sh", "-c", script],
            input=key,
            text=True,
            stdout=subprocess.DEVNULL,
            check=True,
        )

    def delete(self) -> None:
        ident = self._id()
        if ident is not None:
            subprocess.run(
                ["keyctl", "unlink", ident, "@u"], stdout=subprocess.DEVNULL, check=True
            )


class Keychain:
    def _account(self) -> str:
        return os.environ.get("USER", "secrets")

    def get(self) -> str | None:
        found = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                NAME,
                "-a",
                self._account(),
                "-w",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return found.stdout.strip() + "\n" if found.returncode == 0 else None

    def put(self, key: str) -> None:
        # `security -i` reads the command from stdin, so the key never sits in
        # an argv where `ps` shows it.
        command = (
            f"add-generic-password -U -s {NAME} -a {self._account()} -w {key.strip()}\n"
        )
        subprocess.run(
            ["security", "-i"],
            input=command,
            text=True,
            stdout=subprocess.DEVNULL,
            check=True,
        )

    def delete(self) -> None:
        subprocess.run(
            ["security", "delete-generic-password", "-s", NAME, "-a", self._account()],
            capture_output=True,
            check=False,
        )


def default() -> Keystore:
    return Keychain() if sys.platform == "darwin" else KernelKeyring()
