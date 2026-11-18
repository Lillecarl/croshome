"""A remote caller answers box's initrd prompt through the initrd's own tunnel.

box reboots into `gated`, whose initrd waits for a password. hub reaches
10.44.33.3 only while that initrd runs: stage 2 has no such address, and the
initrd deletes its tunnel before it hands over.
"""

from __future__ import annotations

import anyio
from vivarium_runner import Machine, MachineError, Machines

BACK_WITHIN = 300
# A poll after a reboot first reaches the agent of the guest that went down;
# a short timeout keeps that from costing the whole command timeout.
POLL_TIMEOUT = 5
ANSWER = "opensesame"
# switch-root drops the connection without closing it, so ssh would wait on
# it forever.
SSH = (
    "timeout 30 ssh -tt -p 2222 -i /etc/test-client"
    " -o ServerAliveInterval=2 -o ServerAliveCountMax=3"
    " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.44.33.3"
)


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


async def test(vms: Machines) -> None:
    box, hub = vms.box, vms.hub
    gated = vms.settings["gated"]

    await box.fail("ip link show wg-initrd")
    await box.succeed(f"nix-env --profile /nix/var/nix/profiles/system --set {gated}")
    await box.succeed(f"{gated}/bin/switch-to-configuration boot")
    first = await boot_id(box)
    await box.succeed("systemd-run --on-active=1 systemctl reboot")

    await hub.wait_until_succeeds("ping -c 1 -W 1 10.44.33.3", timeout=BACK_WITHIN)
    print("[test] hub reaches the initrd through its tunnel", flush=True)
    # The agent exits 0 when no prompt is pending yet, so answer until the
    # initrd, and with it the tunnel address, is gone.
    await hub.wait_until_fails(
        f"printf '{ANSWER}\\n' | {SSH} || true; ping -c 1 -W 1 10.44.33.3",
        timeout=BACK_WITHIN,
    )
    print("[test] hub answered the prompt over ssh and the initrd went on", flush=True)

    await next_boot(box, first)
    assert (await box.succeed("readlink /run/booted-system")).strip() == gated
    answer = (await box.succeed("cat /run/unlock-gate")).strip()
    assert answer == ANSWER, f"the gate read {answer!r}"

    supplicant = await box.succeed("journalctl -b -u initrd-wpa-supplicant --no-pager")
    assert "CTRL-EVENT-CONNECTED" in supplicant, supplicant
    assert "Key negotiation completed" in supplicant, supplicant
    print("[test] the initrd joined the WiFi with working keys", flush=True)

    await box.fail("ip link show wg-initrd")
    print("[test] stage 2 has no initrd tunnel", flush=True)
