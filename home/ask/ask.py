"""Ask the person at the keyboard for something, without ever seeing it.

An agent has no terminal. So it cannot run anything that prompts: pinentry
fails with "Inappropriate ioctl for device", and every `--passphrase-fd` needs
the passphrase to come from somewhere. This is that somewhere.

    pw_source() { ask pgp --prompt 'OpenPGP passphrase for the personal key'; }
    ask pgp --prompt '...' | gpg --pinentry-mode loopback --passphrase-fd 0 ...

`ask` opens a socket and waits. The person runs `answer pgp` in their own
terminal, types the secret with no echo, and it comes out of this program's
stdout. The agent writes the script around it and never reads the value.

Be exact about what that is worth. It keeps a credential out of the
conversation and out of the transcript, which is where credentials actually
leak. It is *not* a boundary against the agent: the script runs as you and
holds the secret in memory, so an agent that wanted the value could take it.
This prevents the accident, not the attack.

Only stdout carries the answer. Every message this program prints goes to
stderr, so `pw=$(ask ...)` is exactly what was typed and nothing else.

The socket lives in $XDG_RUNTIME_DIR/ask, mode 0600, so who may answer is a
filesystem question and nothing listens on the network.
"""

import argparse
import os
import socket
import sys
import time


def ask_dir() -> str:
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ask")


def socket_path(ask_id: str) -> str:
    return os.path.join(ask_dir(), f"{ask_id}.sock")


def is_live(path: str) -> bool:
    """Whether something is really waiting there.

    A socket file outlives the process that made it, so its presence proves
    nothing. Connecting is the only honest test.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(1)
        sock.connect(path)
        return True
    except OSError:
        return False
    finally:
        sock.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="ask",
        description="Wait for a person to supply a secret, and print it on stdout.",
    )
    parser.add_argument("id", help="name for this request; `answer <id>` replies to it")
    parser.add_argument(
        "--prompt",
        default="",
        help="what to show the person. Say which secret and what it is for",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="seconds to wait before giving up (default 300)",
    )
    parser.add_argument(
        "--newline",
        action="store_true",
        help="append a newline to the answer. Off by default, because gpg's "
        "--passphrase-fd takes the whole of stdin up to EOF",
    )
    args = parser.parse_args()

    directory = ask_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = socket_path(args.id)

    if os.path.exists(path):
        if is_live(path):
            sys.exit(f"ask: something is already waiting on {args.id}")
        os.unlink(path)  # left behind by an ask that is gone

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(1)
        server.settimeout(args.timeout)

        print(f"ask: waiting for `answer {args.id}` ({args.timeout}s)", file=sys.stderr)

        # Keep waiting until somebody actually says something, rather than
        # taking the first connection as the answer. `answer` with no argument
        # lists what is pending, and it does that by connecting and hanging up
        # -- a socket file outlives its process, so connecting is the only
        # honest liveness test. An accept-once version treated that probe as
        # the reply and died on a broken pipe.
        deadline = time.monotonic() + args.timeout
        chunks: list[bytes] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                sys.exit(f"ask: nobody answered {args.id} within {args.timeout}s")
            server.settimeout(remaining)

            try:
                conn, _ = server.accept()
            except socket.timeout:
                sys.exit(f"ask: nobody answered {args.id} within {args.timeout}s")

            with conn:
                conn.settimeout(max(remaining, 1))
                try:
                    # The prompt first, so `answer` can say what it is asking
                    # for rather than showing a bare cursor.
                    conn.sendall(args.prompt.encode() + b"\n")

                    while True:
                        block = conn.recv(4096)
                        if not block:
                            break
                        chunks.append(block)
                except (BrokenPipeError, ConnectionResetError, socket.timeout):
                    chunks.clear()

            if chunks:
                break
            # Nothing said: a liveness probe, or somebody who changed their
            # mind. Neither is an answer, so go back to waiting.
    finally:
        server.close()
        try:
            os.unlink(path)
        except OSError:
            pass

    answer = b"".join(chunks)
    if not answer:
        sys.exit(f"ask: {args.id} was answered with nothing")

    sys.stdout.buffer.write(answer + (b"\n" if args.newline else b""))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
