"""boot-guard reboots an unblessed boot on trial; ai-reboot reboots for a user.

`good` is booted through ai-reboot and blessed. `bad` fails boot-guard's
probe: boot-guard's deadline reboots it twice, and then systemd-boot falls
back to `good`. The host never reboots `bad` itself.
"""

from __future__ import annotations

import re

import anyio
from vivarium_runner import Machine, MachineError, Machines

BACK_WITHIN = 300
# A poll after a reboot first reaches the agent of the guest that went down;
# a short timeout keeps that from costing the whole command timeout.
POLL_TIMEOUT = 5
COUNTERS = re.compile(r"\+(\d+)(?:-(\d+))?\.conf$")


async def boot_id(vm: Machine, timeout: float | None = None) -> str:
    return (await vm.succeed("cat /proc/sys/kernel/random/boot_id", timeout=timeout)).strip()


async def next_boot(vm: Machine, after: str) -> str:
    """The boot id of the first boot after `after`, once its agent answers."""
    with anyio.fail_after(BACK_WITHIN):
        while True:
            await anyio.sleep(2)
            try:
                now = await boot_id(vm, POLL_TIMEOUT)
            except (MachineError, OSError):
                continue
            if now != after:
                return now


async def booted(vm: Machine) -> str:
    return (await vm.succeed("readlink /run/booted-system")).strip()


async def counters(vm: Machine, toplevel: str) -> tuple[int, int] | None:
    """The entry's tries left and tries done, or None once it is blessed."""
    found = await vm.succeed(f"grep -l 'init={toplevel}/init' /boot/loader/entries/*.conf")
    names = found.split()
    assert len(names) == 1, f"{toplevel} has the entries {names}"
    match = COUNTERS.search(names[0])
    if match is None:
        return None
    return int(match[1]), int(match[2] or 0)


async def ai_reboot(vm: Machine, *args: str) -> None:
    # Detached, so the command returns before the agent goes down.
    await vm.succeed(f"systemd-run --uid=alice --on-active=1 /run/current-system/sw/bin/ai-reboot {' '.join(args)}")


async def install(vm: Machine, target: str) -> None:
    await vm.succeed(f"nix-env --profile /nix/var/nix/profiles/system --set {target}")
    await vm.succeed(f"{target}/bin/switch-to-configuration boot")
    assert await counters(vm, target) == (2, 0), "a new entry does not start at 2 tries"


async def test(vms: Machines) -> None:
    vm = vms.one
    good = vms.settings["good"]
    bad = vms.settings["bad"]
    await vm.succeed("test -d /sys/firmware/efi")

    rc, out = await vm.execute("su - alice -c ai-reboot 2>&1")
    assert rc == 1, f"ai-reboot rebooted with no TPM token: rc={rc} {out}"
    assert "no systemd-tpm2 token" in out, out
    print("[test] ai-reboot refuses a device with no TPM token", flush=True)

    await install(vm, good)
    first = await boot_id(vm)
    await ai_reboot(vm, "--no-tpm-check")
    await next_boot(vm, first)
    assert await booted(vm) == good, f"booted {await booted(vm)}, not good"
    await vm.wait_for_unit("systemd-bless-boot.service")
    assert await counters(vm, good) is None, "good was not blessed"
    print("[test] ai-reboot rebooted into good, and boot-guard let it be blessed", flush=True)

    await install(vm, bad)
    last = await boot_id(vm)
    await ai_reboot(vm, "--no-tpm-check")
    systems: list[str] = []
    with anyio.fail_after(3 * BACK_WITHIN):
        while not systems or systems[-1] != good:
            last = await next_boot(vm, last)
            try:
                systems.append(await booted(vm))
            except (MachineError, OSError):
                # boot-guard rebooted it between two calls; the next boot counts.
                continue
    assert systems[0] == bad, f"the first boot after installing bad was {systems[0]}"
    assert await counters(vm, bad) == (0, 2), await counters(vm, bad)
    deadline = await vm.succeed("journalctl -b -1 -u boot-guard-deadline --no-pager")
    assert "rebooting" in deadline, deadline
    print(f"[test] boot-guard rebooted bad until systemd-boot fell back to good: {systems}", flush=True)
