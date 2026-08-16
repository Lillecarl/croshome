# Agent Guidelines

## Layout

Three machines share one configuration.

| Path            | What it is                                                    |
| --------------- | ------------------------------------------------------------- |
| `default.nix`   | The entry point. Builds `pkgs` and each host.                  |
| `hosts/macbook` | nix-darwin. `./rebuild build`, `./rebuild switch`.             |
| `hosts/hetztop` | NixOS. `nixos-rebuild switch --file . --attr hetztop`.         |
| `hosts/cros`    | home-manager alone on ChromeOS. Deliberately small.            |
| `home/`         | Shared home-manager config. `macbook` and `hetztop` import it. |
| `home/darwin/`  | Loaded only on macOS.                                          |
| `home/linux/`   | Loaded only on Linux.                                          |
| `pkgs/`         | The overlay, applied to every host.                            |

ChromeOS has no wrapper script. Build and run the activation package:

```sh
nix-build . --attr cros.activationPackage && ./result/activate
```

`home-manager switch --file .` does **not** work here. That flag takes a module
to build a configuration from, and `hosts/cros/home.nix` is one half of a
configuration that `default.nix` has already assembled.

Three rules to keep in mind when you edit this repo:

- **Do not read `pkgs` to decide an `imports` list.** `imports` is resolved
  before `config` exists, so reading `pkgs` there makes the module system
  recurse. Use the `platform` specialArg, which `default.nix` builds from the
  system string with `lib.systems.elaborate`. It has `isDarwin` and `isLinux`.
- **`hosts/cros` does not import `home/`.** That machine is very slow, and it
  only has to run foot and reach the other two. Add to it by name, not by
  sharing.
- **Run the binary before you call a package Linux-only.** `home/linux/` is for
  things that cannot work on macOS, and three different signals all lie about
  which those are:
  - `meta.platforms` says a package is *allowed* on a platform, not that it
    works there.
  - A green build says it *compiled*, not that it runs.
  - A red build often means `versionCheckPhase` got no output from the binary
    inside the sandbox, while the same store path runs fine outside it. Build
    with `doInstallCheck = false` and run it before believing the failure.

  `opencode` and `kilocode-cli` sat in `home/linux/` for exactly this reason
  and both run on macOS. Check the upstream release assets too: `opencode`
  publishes a macOS CLI, and the comment claiming otherwise was wrong.

## The Linux builders on the MacBook

| | `nix.linux-vz-builder` | `nix.linux-builder` |
| --- | --- | --- |
| Hypervisor | Virtualization.framework (vfkit) | QEMU + HVF |
| Systems | aarch64-linux, **x86_64-linux** | aarch64-linux |
| Lifetime | socket-activated, exits after 60s idle | always on |
| Disk | none; the host store is the lower layer | qcow2 image |
| State | **in use** | kept, `enable = false` |

x86_64-linux only works on the VZ one. Rosetta-for-Linux is a
Virtualization.framework feature, so no amount of QEMU configuration reaches
it.

The QEMU one is disabled but deliberately not deleted: it is the way back if
the VZ builder breaks. If the VZ *guest* is what needs fixing, turn
`nix.linux-vz-builder.enable` off in the same edit -- the guest is an
aarch64-linux system, so building a changed one needs a Linux builder, and
that is the deadlock. It is not hypothetical; see the commit that added the
activation check.

To use the VZ builder, just build something: connecting to 127.0.0.1:31122 is
what starts it. `hosts/macbook/vz-builder/guest.nix` is a whole NixOS system,
so changing it means an aarch64-linux rebuild.

`nix.linux-vz-builder.debugAccess` (off by default) authorises the keypair
nixpkgs ships for its builder VM -- world-readable, so an already-public key --
and lets you in for profiling:

```sh
key="$(nix eval --raw -f . inputs.nixpkgs)/nixos/modules/profiles/keys/ssh_host_ed25519_key"
ssh -i "$key" -p 31122 builder@127.0.0.1 systemd-analyze blame
ssh -i "$key" -p 31122 root@127.0.0.1 systemctl poweroff   # beats waiting out the idle timer
```

Four things there were measured rather than read, and are easy to get wrong:

- macOS **bootpd serves no DNS**. The DHCP hostname lands in
  `/var/db/dhcpd_leases` and resolves nowhere. mDNS is what works, which is why
  the guest runs avahi and is reached at `vzbuilder.local`.
- A macOS **unix socket path cannot exceed 104 bytes**, which the scratchpad
  directory alone can exceed.
- `unix://` **cannot retrieve build results** from a daemon in a VM. It asks
  the daemon whether a path is valid, then reads the contents off the *local*
  filesystem, so builds succeed and nothing can be read back. Use `ssh-ng://`.
  Reported as Lillecarl/nix#307.
- A guest change is not in effect until the VM has **restarted onto it**.
  Measuring a still-resident VM after a rebuild reads as confirmation and is
  not. Activation now stops a stale VM for this reason.

## Reading a change before activating it

Never activate without reading the diff first.

- `./rebuild diff` lists the packages a switch would add, drop or move.
- `./rebuild diff-drv` says *why* a derivation differs, for when no version
  moved and everything rebuilt anyway.

## Version Control

This repo uses **jj (Jujutsu)** as its VCS. Always use jj commands instead of git.

- Load the **jj** skill before performing any version control operations
- Load the **jj-hunk** skill for partial commits, splits, or selective squashing
- Use `jj --no-pager` for all jj commands to avoid pager issues
- Prefer `jj commit -m "msg"` over `jj describe` when finishing a task
- Never use `git` directly — use jj equivalents instead