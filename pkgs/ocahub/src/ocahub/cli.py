"""ocac: the ocahub client CLI. One JSON object per event on stdout.

Exit codes: 0 ok, 1 hub unreachable, 2 timed out waiting, 3 hub error.
"""

import argparse
import base64
import json
import os
import socket
import sys
import time

import zmq

from . import protocol as P
from .daemon import runtime_dir

EXIT_OK = 0
EXIT_UNREACHABLE = 1
EXIT_TIMEOUT = 2
EXIT_HUB = 3


class Unreachable(Exception):
    pass


class WaitTimeout(Exception):
    pass


class HubError(Exception):
    pass


def decode_payload(payload: bytes):
    try:
        return payload.decode()
    except UnicodeDecodeError:
        return {"b64": base64.b64encode(payload).decode()}


def emit(obj):
    if hasattr(obj, "to_dict"):
        obj = obj.to_dict()
    print(json.dumps(obj, separators=(",", ":")), flush=True)


def default_session():
    return os.environ.get("OCAHUB_SESSION") or f"{socket.gethostname()}.{os.getpid()}"


class Client:
    def __init__(self, runtime=None, timeout=None):
        self.runtime = runtime or runtime_dir()
        self.timeout = float(
            timeout or os.environ.get("OCAHUB_TIMEOUT") or 5.0
        )
        self.ctx = zmq.Context()

    def dealer(self):
        d = self.ctx.socket(zmq.DEALER)
        d.setsockopt(zmq.LINGER, 0)
        d.setsockopt(zmq.SNDTIMEO, int(self.timeout * 1000))
        d.connect(f"ipc://{self.runtime}/router.sock")
        return d

    def request(self, dealer, msg, payload=b""):
        """Send one request, then read frames until the ACK, keeping DELIVERs.

        Mailbox drains arrive as DELIVERs before the ACK on the same pipe, so
        the caller sees them in order.
        """
        dealer.send_multipart(P.encode(msg, payload))
        delivers = []
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = max(0.05, deadline - time.monotonic())
            dealer.setsockopt(zmq.RCVTIMEO, int(remaining * 1000))
            try:
                frames = dealer.recv_multipart()
            except zmq.error.Again as e:
                raise Unreachable("hub did not answer in time") from e
            m, pl = P.decode(frames)
            if m.type == P.DELIVER:
                delivers.append((m, pl))
                continue
            if m.type == P.ACK:
                return m, delivers
            raise HubError(m.error)

    def call(self, msg, payload=b""):
        d = self.dealer()
        try:
            return self.request(d, msg, payload)
        finally:
            d.close(0)

    def ping(self):
        return self.call(P.Ping())[0]

    def hello(self, name, session, caps=(), cwd=None):
        return self.call(P.Hello(name=name, session=session, caps=list(caps), cwd=cwd))

    def who(self):
        return self.call(P.Who())[0]

    def send(self, to=None, topic=None, reply_to=None, kind=P.KIND_TELL, payload=b"", cwd=None):
        return self.call(
            P.Send(to=to, topic=topic, reply_to=reply_to, kind=P.check_kind(kind), cwd=cwd),
            payload,
        )[0]

    def broadcast(self, topic="user", payload=b""):
        return self.call(P.Broadcast(topic=topic), payload)[0]

    def asks(self, name, session):
        return self.call(P.Asks(name=name, session=session))[0]

    def send_wait(
        self,
        to=None,
        topic=None,
        reply_to=None,
        kind=P.KIND_TELL,
        payload=b"",
        wait=30.0,
        cwd=None,
    ):
        msg = P.Send(
            to=to,
            topic=topic,
            reply_to=reply_to,
            kind=P.check_kind(kind),
            cwd=cwd,
        )
        d = self.dealer()
        try:
            ack, delivers = self.request(d, msg, payload)
            if not ack.ok:
                raise HubError(ack.error or "unknown hub error")
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WaitTimeout("no reply arrived in time")
                d.setsockopt(zmq.RCVTIMEO, int(min(remaining, 0.25) * 1000))
                try:
                    m, pl = P.decode(d.recv_multipart())
                except zmq.error.Again:
                    continue
                except P.ProtocolError:
                    continue
                if m.type == P.DELIVER and m.reply_to == msg.id:
                    return ack, m, pl
        finally:
            d.close(0)

    def poll_wait(self, name, session, wait=30.0, cwd=None):
        d = self.dealer()
        try:
            ack, delivers = self.request(d, P.Poll(name=name, session=session, cwd=cwd))
            if delivers:
                return ack, *delivers[0]
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WaitTimeout("no message arrived in time")
                d.setsockopt(zmq.RCVTIMEO, int(min(remaining, 0.25) * 1000))
                try:
                    m, pl = P.decode(d.recv_multipart())
                except zmq.error.Again:
                    continue
                except P.ProtocolError:
                    continue
                if m.type == P.DELIVER:
                    return ack, m, pl
        finally:
            d.close(0)

    def close(self):
        self.ctx.destroy(linger=0)


def read_payload(args):
    if args.stdin:
        return sys.stdin.buffer.read()
    if args.message is not None:
        return args.message.encode()
    return b""


def cmd_hello(c, args):
    ack, delivers = c.hello(
        args.name,
        args.session,
        [x for x in args.caps.split(",") if x],
        cwd=args.cwd or os.getcwd(),
    )
    for m, pl in delivers:
        emit({**m.to_dict(), "payload": decode_payload(pl)})
    emit(ack)
    return EXIT_OK


def cmd_send(c, args):
    payload = read_payload(args)
    if args.wait is None:
        ack = c.send(
            to=args.to,
            topic=args.topic,
            reply_to=args.reply_to,
            kind=args.kind,
            payload=payload,
            cwd=args.cwd,
        )
        emit(ack)
        return EXIT_OK if ack.ok else EXIT_HUB
    ack, m, pl = c.send_wait(
        to=args.to,
        topic=args.topic,
        reply_to=args.reply_to,
        kind=args.kind,
        payload=payload,
        wait=args.wait,
        cwd=args.cwd,
    )
    emit(ack)
    emit({**m.to_dict(), "payload": decode_payload(pl)})
    return EXIT_OK


def cmd_broadcast(c, args):
    ack = c.broadcast(topic=args.topic, payload=read_payload(args))
    emit(ack)
    return EXIT_OK if ack.ok else EXIT_HUB


def cmd_poll(c, args):
    name = args.name or os.environ.get("OCAHUB_NAME")
    session = args.session or os.environ.get("OCAHUB_SESSION")
    if args.wait is None:
        if not (name and session):
            print(
                "ocac: poll needs --name/--session (or OCAHUB_NAME/OCAHUB_SESSION)",
                file=sys.stderr,
            )
            return EXIT_HUB
        ack, delivers = c.call(P.Poll(name=name, session=session))
        for m, pl in delivers:
            emit({**m.to_dict(), "payload": decode_payload(pl)})
        emit(ack.to_dict())
        return EXIT_OK
    if not (name and session):
        print("ocac: poll --wait needs --name/--session", file=sys.stderr)
        return EXIT_HUB
    ack, m, pl = c.poll_wait(name, session, wait=args.wait)
    emit(ack)
    emit({**m.to_dict(), "payload": decode_payload(pl)})
    return EXIT_OK


def cmd_sub(c, args):
    sub = c.ctx.socket(zmq.SUB)
    sub.setsockopt(zmq.LINGER, 0)
    sub.setsockopt(zmq.SUBSCRIBE, args.topic.encode())
    sub.setsockopt(zmq.RCVTIMEO, 250)
    sub.connect(f"ipc://{c.runtime}/xpub.sock")
    try:
        while True:
            try:
                frames = sub.recv_multipart()
            except zmq.error.Again:
                continue
            except KeyboardInterrupt:
                return EXIT_OK
            topic = frames[0]
            m, pl = P.decode(frames[1:])
            emit(
                {
                    **m,
                    "topic": topic.decode(errors="replace"),
                    "payload": decode_payload(pl),
                }
            )
    except KeyboardInterrupt:
        return EXIT_OK
    finally:
        sub.close(0)


def cmd_asks(c, args):
    name = args.name or os.environ.get("OCAHUB_NAME")
    session = args.session or os.environ.get("OCAHUB_SESSION")
    if not (name and session):
        print("ocac: asks needs --name/--session (or OCAHUB_NAME/OCAHUB_SESSION)", file=sys.stderr)
        return EXIT_HUB
    ack = c.asks(name, session)
    print(json.dumps(ack.asks or [], separators=(",", ":")))
    return EXIT_OK


def cmd_bye(c, args):
    ack = c.call(P.Bye(name=args.name, session=args.session))[0]
    emit(ack.to_dict())
    return EXIT_OK


def cmd_who(c, args):
    ack = c.who()
    print(json.dumps(ack.sessions, separators=(",", ":")))
    return EXIT_OK


def cmd_ping(c, args):
    emit(c.ping().to_dict())
    return EXIT_OK


def build_parser():
    ap = argparse.ArgumentParser(prog="ocac", description="Talk to the ocahub agent hub")
    ap.add_argument("--runtime-dir", default=None, help="override the hub runtime directory")
    ap.add_argument("--timeout", type=float, default=5.0, help="seconds per request to the hub")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping", help="is the hub reachable?")

    sub.add_parser("who", help="list registered sessions")

    p = sub.add_parser("hello", help="register a session")
    p.add_argument("--name", required=True)
    p.add_argument("--session", default=default_session())
    p.add_argument("--caps", default="", help="comma-separated capability tags")
    p.add_argument("--cwd", default=None, help="working directory to advertise")

    p = sub.add_parser("send", help="send to NAME[@SESSION]; reply with --reply-to ID")
    p.add_argument("--to", default=None)
    p.add_argument(
        "--cwd",
        default=None,
        help="target the most recent online session working in a matching directory",
    )
    p.add_argument(
        "--kind",
        default=P.KIND_TELL,
        choices=(P.KIND_TELL, P.KIND_ASK, P.KIND_REPLY),
        help="tell = fire and forget; ask = a reply is owed; reply = answers an ask, "
        "passed through as a tell when the ask is gone",
    )
    p.add_argument("--topic", default=None)
    p.add_argument("--reply-to", dest="reply_to", default=None)
    p.add_argument("-m", "--message", default=None)
    p.add_argument("--stdin", action="store_true", help="read the payload from stdin")
    p.add_argument(
        "--wait",
        nargs="?",
        const=30.0,
        type=float,
        default=None,
        metavar="SECS",
        help="block for the reply (default 30s)",
    )

    p = sub.add_parser("broadcast", help="publish to all subscribers of a topic")
    p.add_argument("--topic", default="user")
    p.add_argument("-m", "--message", default=None)
    p.add_argument("--stdin", action="store_true", help="read the payload from stdin")

    p = sub.add_parser("poll", help="drain your mailbox; --wait blocks for one message")
    p.add_argument("--name", default=None)
    p.add_argument("--session", default=None)
    p.add_argument(
        "--wait",
        nargs="?",
        const=30.0,
        type=float,
        default=None,
        metavar="SECS",
        help="block for one message (default 30s)",
    )

    p = sub.add_parser("sub", help="stream broadcasts and hub events")
    p.add_argument("--topic", default="", help="topic prefix to match (empty = all)")

    p = sub.add_parser("asks", help="list asks still owed by a session (read-only)")
    p.add_argument("--name", default=None)
    p.add_argument("--session", default=None)

    p = sub.add_parser("bye", help="unregister the session named by --name/--session")
    p.add_argument("--name", required=True)
    p.add_argument("--session", default=default_session())

    return ap


COMMANDS = {
    "ping": cmd_ping,
    "who": cmd_who,
    "hello": cmd_hello,
    "send": cmd_send,
    "broadcast": cmd_broadcast,
    "poll": cmd_poll,
    "asks": cmd_asks,
    "sub": cmd_sub,
    "bye": cmd_bye,
}


def main(argv=None):
    args = build_parser().parse_args(argv)
    c = Client(runtime=args.runtime_dir, timeout=args.timeout)
    try:
        return COMMANDS[args.cmd](c, args)
    except Unreachable as e:
        print(f"ocac: {e}; is the ocahub service running?", file=sys.stderr)
        return EXIT_UNREACHABLE
    except WaitTimeout as e:
        print(f"ocac: {e}", file=sys.stderr)
        return EXIT_TIMEOUT
    except HubError as e:
        print(f"ocac: hub error: {e}", file=sys.stderr)
        return EXIT_HUB
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())
