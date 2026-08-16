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
| Disk | ephemeral raw images, recreated per start | qcow2 image |
| Store writes | 128G ext4 on /dev/vda | in the image |
| Swap | 16G on /dev/vdb | none |
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

### Running Linux commands: `vzrun`

`vzrun` runs a command in the builder, for Linux-only work that a build sandbox
cannot do -- something that wants a network, a real `/proc`, a mount namespace,
or just a shell.

```sh
vzrun uname -m                 # aarch64
vzrun --root mount             # root in the guest; see below
vzrun                          # interactive shell
```

It connects to the same port a distributed build does, so it starts the VM the
same way and the idle watchdog counts it the same way. An open session holds
the VM up; closing it starts the 60s clock. Measured: **7.9s cold** (that is
the guest booting) and **63ms warm**, the second because ssh multiplexing keeps
one connection for 30s.

The useful part is that **`/nix/store` in the guest is this Mac's store**,
through the overlay. So a Linux binary built here can simply be run:

```sh
nix build --file . <attr> && vzrun ./result/bin/<x>
```

`vzrun` starts in `$PWD` when the guest has a directory by that name, which is
why the line above works, and falls back to `/nix/.rw-store/build` when it does
not. Nothing else of this Mac is visible -- there is no share of `$HOME`.

Scratch used to be a virtiofs share of a host directory, and that is why
**meson reported clock skew**: the guest runs ~70ms behind macOS, so a file
written through virtiofs came back with an mtime in the guest's future. It
lives on the guest's own ext4 now, where the clock that writes a timestamp is
the clock that reads it. The read-only store share is the only virtiofs left in
a build's path and cannot skew anything, because Nix normalises store
timestamps to the epoch (`mtime=1`).

A store path added on the Mac **while the VM runs** behaves in two ways at
once, and both were measured against one VM instance:

| | new path added mid-run |
| --- | --- |
| `vzrun ls $p/bin` | works -- overlayfs reads the lower layer live |
| `vzrun nix path-info $p` | "this path will be fetched" -- not valid |

The daemon holds the lower store's SQLite open as `immutable`, so its view of
the *database* is frozen at boot while its view of the *files* is not. This
does not affect `vzrun`, which goes to the filesystem and never asks Nix. It
does mean a build inside the guest may refetch something the Mac already has.
Restarting the VM re-reads the database.

Two more things worth knowing:

- `nix.linux-vz-builder.authorizedKeys` is what makes it work, and it is a
  separate mechanism from `debugAccess`. The builder key in `/etc/nix` is
  `root:nixbld 0600`, so it is not an answer for an ordinary user.
- Those keys are listed **globally** in the guest's sshd, not per user, so they
  log in as `root` too. `--root` is that. The guest is disposable and reachable
  only from this Mac, and `builder` is a trusted Nix user that can run anything
  there by submitting a derivation, so root adds no reachable privilege.

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