"""Reply to a waiting `ask`, with the typing kept off the screen.

    answer                 what is waiting
    answer pgp             type the secret for that request
    answer pgp --echo      for an answer that is not a secret

`ask` runs inside an agent's script and blocks. This runs in your terminal,
shows you what is being asked for, reads it with the echo off, and hands it
back. The agent's script gets the value on ask's stdout; the agent gets
nothing.

Echo is off because `getpass` reads /dev/tty directly and turns it off there.
That matters more than it sounds: an earlier attempt at this ran the whole
thing under `script`, whose extra pty broke exactly that, and the passphrase
appeared on screen and went into a log file. Nothing wraps the terminal here.

Nothing is written to disk. The value goes straight down the socket.
"""

import argparse
import getpass
import os
import socket
import sys


def ask_dir() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ask")


def is_live(path: str) -> bool:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(1)
        sock.connect(path)
        return True
    except OSError:
        return False
    finally:
        sock.close()


def pending() -> list[str]:
    directory = ask_dir()
    if not os.path.isdir(directory):
        return []
    return [
        name[: -len(".sock")]
        for name in sorted(os.listdir(directory))
        if name.endswith(".sock") and is_live(os.path.join(directory, name))
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="answer",
        description="Supply a secret to a waiting `ask`, without echoing it.",
    )
    parser.add_argument("id", nargs="?", help="which request; omit to list them")
    parser.add_argument(
        "--echo",
        action="store_true",
        help="show what you type. For an answer that is not a secret",
    )
    args = parser.parse_args()

    waiting = pending()

    if args.id is None:
        if not waiting:
            print("nothing is waiting for an answer")
            return 0
        print("waiting:")
        for name in waiting:
            print(f"  {name}")
        return 0

    path = os.path.join(ask_dir(), f"{args.id}.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(10)
        sock.connect(path)
    except FileNotFoundError:
        sys.exit(f"answer: nothing is waiting on {args.id}")
    except ConnectionRefusedError:
        sys.exit(f"answer: {args.id} left a stale socket behind; it is not waiting")

    with sock:
        # The prompt the asker set, so you know what you are typing into.
        sock.settimeout(10)
        prompt = b""
        while not prompt.endswith(b"\n"):
            block = sock.recv(1)
            if not block:
                break
            prompt += block
        text = prompt.decode("utf-8", "replace").strip()

        label = text if text else f"answer for {args.id}"
        # No timeout while a person is typing. The asker has its own.
        sock.settimeout(None)
        value = input(f"{label}: ") if args.echo else getpass.getpass(f"{label}: ")

        if not value:
            sys.exit("answer: refusing to send nothing")

        sock.sendall(value.encode())
        # Half-close, so the asker's read-to-EOF returns rather than waiting
        # for this process to exit.
        sock.shutdown(socket.SHUT_WR)

    print("sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
