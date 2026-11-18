"""Keys and motion routed by the numpad reach the nested VM on USB HID only.

The nested VM also has PS/2 and virtio input. QEMU gives evdev events to
the device activated last, which is the hot-plugged USB pair. Windows has
no virtio-input driver, so an event seen on bus 0006 would be lost there.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from vivarium_runner import Machine, Machines

CONSOLE = "/var/log/libvirt/qemu/nested-console.log"
USB = "0003"
EV_KEY, EV_REL = 1, 2
KEY_A, KEY_B, REL_X = 30, 48, 0
EVENT = re.compile(r"^EV bus=(\w+) type=(\d+) code=(\d+) value=(-?\d+)", re.MULTILINE)


async def events(vm: Machine) -> list[tuple[str, int, int, int]]:
    # -v: the console holds a 0xff byte, which the agent cannot decode (nixidae/nixidae#1513).
    log = (await vm.succeed(f"cat -v {CONSOLE}")).stdout
    return [(bus, int(t), int(c), int(v)) for bus, t, c, v in EVENT.findall(log)]


async def send(vm: Machine, line: str) -> None:
    await vm.succeed(f"echo '{line}' > /run/fake-input")


def presses(found: list[tuple[str, int, int, int]], code: int) -> list[str]:
    """The bus of each press of `code`."""
    return [bus for bus, t, c, v in found if t == EV_KEY and c == code and v == 1]


async def test(vms: Machines) -> None:
    vm = vms.host
    await vm.wait_for_unit("fake-input.service")
    await vm.wait_for_unit("remapper.service")
    await vm.succeed("virsh define /etc/nested.xml && virsh start nested")
    await vm.wait_until_succeeds(f"grep -q READY {CONSOLE}", timeout=120)
    print((await vm.succeed(f"grep -E 'WATCH|MODPROBE' {CONSOLE}")).stdout, flush=True)

    # The key and the motion are repeated until they arrive somewhere: the
    # bus they arrive on is the verdict, not whether a USB device appeared.
    await send(vm, "tap KEY_KP1")
    await vm.wait_until_succeeds(
        f"echo 'tap KEY_A' > /run/fake-input; grep -q 'type={EV_KEY} code={KEY_A} value=1' {CONSOLE}",
        timeout=60,
    )
    await vm.wait_until_succeeds(
        f"echo 'move 5' > /run/fake-input; grep -q 'type={EV_REL} code={REL_X} value=5' {CONSOLE}",
        timeout=60,
    )
    found = await events(vm)
    keys = presses(found, KEY_A)
    moves = [bus for bus, t, c, _ in found if t == EV_REL and c == REL_X]
    assert keys and set(keys) == {USB}, f"KEY_A arrived on buses {keys}"
    assert moves and set(moves) == {USB}, f"REL_X arrived on buses {moves}"
    print(f"[test] {len(keys)} key presses and {len(moves)} moves, all on USB", flush=True)
    xml = (await vm.succeed("virsh dumpxml nested")).stdout
    for alias in ("ua-remapper", "ua-remapper-keyboard", "ua-remapper-mouse"):
        assert f"'{alias}'" in xml, f"{alias} is not attached:\n{xml}"

    await send(vm, "tap KEY_KP2")
    await vm.wait_until_succeeds("journalctl -u remapper | grep -q 'input to the host'", timeout=30)
    await send(vm, "tap KEY_B")
    # KEY_A, typed after the way back, is a marker: KEY_B, if it were
    # routed, would arrive before it.
    before = len(keys)
    await send(vm, "tap KEY_KP1")
    await vm.wait_until_succeeds("journalctl -u remapper | grep -c 'input to the VM' | grep -qx 2", timeout=30)
    await vm.wait_until_succeeds(
        f"echo 'tap KEY_A' > /run/fake-input; [ $(grep -c 'type={EV_KEY} code={KEY_A} value=1' {CONSOLE}) -gt {before} ]",
        timeout=60,
    )
    found = await events(vm)
    assert presses(found, KEY_B) == [], "KEY_B, typed on the host, reached the VM"
    assert set(presses(found, KEY_A)) == {USB}
    print("[test] on the host, nothing reached the VM; back in it, USB again", flush=True)
