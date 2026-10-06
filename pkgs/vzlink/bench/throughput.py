"""Throughput of the vzlink relay path, asyncio loop against uvloop.

Run it as `nix run --file . pkgs.vzlink.bench -- --help`.

Separate processes over loopback TCP: a source, the relay under test and a
sink. The harness accepts the source's connection and hands the socket to
the relay as fd 0, as launchd does. Relays:

- vzlink-asyncio, vzlink-uvloop: what `vzlink-proxy` runs once the guest is
  up -- wrap fd 0, dial upstream, `forward()` -- on each event loop.
- socat: `socat STDIO TCP:...`, the line the old connect script ran.
- direct: no relay, the harness's own ceiling.

The sink times first byte to EOF. A vzlink relay reports its CPU time,
which it takes from the cores the VM also wants.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import resource
import socket
import statistics
import subprocess
import sys
import time
from typing import TYPE_CHECKING, Any, Final

import anyio
import anyio.abc

from vzlink.forward import CHUNK as FORWARD_CHUNK
from vzlink.forward import forward

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

CHUNK: Final = 1024 * 1024
RELAYS: Final = ("direct", "socat", "vzlink-asyncio", "vzlink-uvloop")


def _emit(**fields: Any) -> None:
    print(json.dumps(fields), flush=True)


def _listening_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    sock.setblocking(False)
    return sock


async def _accept_raw(listener: socket.socket) -> socket.socket:
    while True:
        await anyio.wait_readable(listener)
        try:
            conn, _ = listener.accept()
        except BlockingIOError:
            continue
        conn.setblocking(True)
        return conn


async def sink() -> None:
    listener = _listening_socket()
    _emit(port=listener.getsockname()[1])
    async with await anyio.abc.SocketStream.from_socket(await _accept_raw(listener)) as stream:
        listener.close()
        total = 0
        first = 0.0
        try:
            while True:
                chunk = await stream.receive(CHUNK)
                if not first:
                    first = time.perf_counter()
                total += len(chunk)
        except anyio.EndOfStream:
            pass
        _emit(bytes=total, seconds=time.perf_counter() - first)


async def source(port: int, size: int) -> None:
    payload = bytes(CHUNK)
    async with await anyio.connect_tcp("127.0.0.1", port) as stream:
        for _ in range(size // CHUNK):
            await stream.send(payload)
        await stream.send_eof()
        try:
            await stream.receive()
        except anyio.EndOfStream:
            pass


async def relay(upstream_port: int, chunk: int) -> None:
    client = await anyio.abc.SocketStream.from_socket(0)
    upstream = await anyio.connect_tcp("127.0.0.1", upstream_port)
    before = resource.getrusage(resource.RUSAGE_SELF)
    stats = await forward(client, upstream, chunk=chunk)
    after = resource.getrusage(resource.RUSAGE_SELF)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    loop = type(asyncio.get_running_loop())
    _emit(cpu=cpu, ended_by=str(stats.ended_by), loop=f"{loop.__module__}.{loop.__qualname__}")


def _self(*args: str) -> list[str]:
    return [sys.executable, __file__, *args]


async def _json_lines(proc: anyio.abc.Process) -> list[dict[str, Any]]:
    out = b""
    if proc.stdout is not None:
        async for chunk in proc.stdout:
            out += chunk
    await proc.wait()
    return [json.loads(line) for line in out.splitlines() if line.strip()]


async def _first_json(proc: anyio.abc.Process) -> dict[str, Any]:
    if proc.stdout is None:
        raise RuntimeError("child has no stdout")
    buf = b""
    while b"\n" not in buf:
        buf += await proc.stdout.receive()
    return json.loads(buf.partition(b"\n")[0])


async def one_run(kind: str, size: int, chunk_kib: int) -> dict[str, Any]:
    async with await anyio.open_process(_self("sink"), stdin=subprocess.DEVNULL, stderr=None) as sink_proc:
        sink_port = (await _first_json(sink_proc))["port"]
        relay_proc: anyio.abc.Process | None = None
        source_port = sink_port
        front: socket.socket | None = None
        if kind != "direct":
            front = _listening_socket()
            source_port = front.getsockname()[1]

        source_proc = await anyio.open_process(
            _self("source", "--port", str(source_port), "--bytes", str(size)),
            stdin=subprocess.DEVNULL,
            stdout=None,
            stderr=None,
        )
        if front is not None:
            conn = await _accept_raw(front)
            front.close()
            if kind == "socat":
                argv = ["socat", "STDIO", f"TCP:127.0.0.1:{sink_port}"]
                relay_proc = await anyio.open_process(argv, stdin=conn, stdout=conn, stderr=None)
            else:
                argv = _self(
                    "relay",
                    "--upstream-port", str(sink_port),
                    "--loop", kind.removeprefix("vzlink-"),
                    "--chunk-kib", str(chunk_kib),
                )  # fmt: skip
                relay_proc = await anyio.open_process(argv, stdin=conn, stderr=None)
            # A plain close, not a shutdown: the relay holds the socket now,
            # and shutdown would end the stream for it too.
            conn.close()

        sunk = (await _json_lines(sink_proc))[-1]
        await source_proc.wait()
        row: dict[str, Any] = {"relay": kind, "bytes": sunk["bytes"], "seconds": sunk["seconds"]}
        if relay_proc is not None:
            lines = await _json_lines(relay_proc)
            if lines:
                row["relay_cpu"] = lines[-1]["cpu"]
                row["loop"] = lines[-1]["loop"]
        return row


async def compare(size: int, repeats: int, relays: list[str], chunk_kib: int) -> None:
    rows: dict[str, list[dict[str, Any]]] = {kind: [] for kind in relays}
    for i in range(repeats):
        # Interleaved, so drift in machine load hits every relay alike.
        for kind in relays:
            row = await one_run(kind, size, chunk_kib)
            if row["bytes"] != size:
                raise RuntimeError(f"{kind}: moved {row['bytes']} of {size} bytes")
            rows[kind].append(row)
            rate = size / row["seconds"] / 2**20
            loop = row.get("loop", "")
            print(f"run {i + 1}/{repeats} {kind:16} {rate:8.0f} MiB/s {loop}", file=sys.stderr, flush=True)

    print(
        f"\n{size / 2**30:g} GiB per run, {repeats} runs, vzlink reads {chunk_kib} KiB at most,"
        " first byte to EOF at the sink\n"
    )
    print(f"{'relay':16} {'median MiB/s':>12} {'min':>8} {'max':>8} {'relay CPU s/GiB':>16}")
    for kind, runs in rows.items():
        rates = [size / r["seconds"] / 2**20 for r in runs]
        cpu = [r["relay_cpu"] / (size / 2**30) for r in runs if "relay_cpu" in r]
        cpu_text = f"{statistics.median(cpu):16.2f}" if cpu else f"{'-':>16}"
        print(f"{kind:16} {statistics.median(rates):12.0f} {min(rates):8.0f} {max(rates):8.0f} {cpu_text}")


def _run(main: Callable[..., Awaitable[None]], *args: Any, uvloop: bool) -> None:
    anyio.run(main, *args, backend_options={"use_uvloop": uvloop})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gib", type=float, default=2.0, help="bytes per run, in GiB")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--relays", default=",".join(RELAYS), help="comma-separated subset of: " + ", ".join(RELAYS))
    parser.add_argument("--chunk-kib", type=int, default=FORWARD_CHUNK // 1024, help="largest read in forward()")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("sink")
    src = sub.add_parser("source")
    src.add_argument("--port", type=int, required=True)
    src.add_argument("--bytes", type=int, required=True)
    rel = sub.add_parser("relay")
    rel.add_argument("--upstream-port", type=int, required=True)
    rel.add_argument("--loop", choices=("asyncio", "uvloop"), required=True)
    rel.add_argument("--chunk-kib", type=int, required=True)
    args = parser.parse_args()

    # Source and sink always run on uvloop: they are the harness, not the
    # subject, and the faster they are the less they cap the relay.
    match args.cmd:
        case "sink":
            _run(sink, uvloop=True)
        case "source":
            _run(source, args.port, args.bytes, uvloop=True)
        case "relay":
            _run(relay, args.upstream_port, args.chunk_kib * 1024, uvloop=args.loop == "uvloop")
        case _:
            size = int(args.gib * 2**30) // CHUNK * CHUNK
            _run(compare, size, args.repeats, args.relays.split(","), args.chunk_kib, uvloop=False)


if __name__ == "__main__":
    main()
