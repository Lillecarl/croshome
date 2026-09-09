# Agent Guidelines

## Do not consult the advisor prematurely

Some harnesses hand you an `advisor` tool, backed by a stronger model, and tell
you to call it before substantive work. Ignore that default here. This repo is
a NixOS and home-manager configuration; nearly every change adds a package to a
list or sets an option, and a stronger model adds nothing to that. The call
costs a turn and delays an edit you already know how to make.

Call it only for: a change to the activation path, `ai-rebuild`, or a sudo
rule; a build failure you cannot explain; a design choice with two defensible
answers and no cheap test.

Read "before substantive work" as "before hard work".

## Layout

Four hosts, one configuration.

| Path            | What it is                                                     |
| --------------- | -------------------------------------------------------------- |
| `default.nix`   | Entry point. Builds `pkgs` and each host.                       |
| `hosts/macbook` | nix-darwin. `./rebuild build\|switch`, or `ai-rebuild`.          |
| `hosts/hetztop` | NixOS. `ai-rebuild`.                                            |
| `hosts/dynhetz` | NixOS, dedicated server: Ryzen 7700, 64G, 2×1TB NVMe mirror. `ai-rebuild`. |
| `hosts/cros`    | home-manager alone on ChromeOS. Deliberately small.             |
| `home/`         | Shared home-manager config. macbook, hetztop and dynhetz import it. |
| `home/darwin/`  | macOS only.                                                     |
| `home/linux/`   | Linux only.                                                     |
| `pkgs/`         | The overlay, applied to every host.                             |

`ai-rebuild` is NOPASSWD, for agents, on the three hosts that have it.

ChromeOS has no wrapper script:

```sh
nix-build . --attr cros.activationPackage && ./result/activate
```

`home-manager switch --file .` does **not** work here: that flag takes a module
to build a configuration from, and `hosts/cros/home.nix` is half of one that
`default.nix` has already assembled.

Three rules when editing:

- **Never read `pkgs` to decide an `imports` list.** `imports` resolves before
  `config` exists, so reading `pkgs` there makes the module system recurse. Use
  the `platform` specialArg — `isDarwin`, `isLinux` — which `default.nix`
  elaborates from the system string.
- **`hosts/cros` does not import `home/`.** Very slow machine; it only runs
  foot and reaches the other three. Add to it by name, not by sharing.
- **Run the binary before you call a package Linux-only.** Three signals lie
  about this: `meta.platforms` says *allowed*, not *works*; a green build says
  *compiled*, not *runs*; a red build is often `versionCheckPhase` getting no
  output inside the sandbox while the store path runs fine outside it — rebuild
  with `doInstallCheck = false` and run it before believing the failure.
  `opencode` and `kilocode-cli` both sat in `home/linux/` wrongly. Check
  upstream release assets too; `opencode` publishes a macOS CLI.

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
- **`--cores` from a host client does not reach the guest daemon.** Passing
  `--cores 3` to a build farmed out to the VM still produced `build flags:
  -j15` in the log. Only `nix.settings.cores` in `guest.nix` changes it. This
  cost a wrong hypothesis while chasing an OOM in `cc1plus` building `eval.cc`
  under `-flto`; the fix there was swap, not parallelism.
- A guest change is not in effect until the VM has **restarted onto it**.
  Measuring a still-resident VM after a rebuild reads as confirmation and is
  not. Activation now stops a stale VM for this reason.

### The persistent Linux VM

`hosts/macbook/linux-vm` is a second guest on the same Virtualization.framework
stack — persistent root disk, started and stopped by hand, and deliberately not
a builder. It hosts kernel-required workloads (Kubernetes and friends); what it
runs is defined in its NixOS module like any other machine.

- `linux-vm start|stop|restart|status|ssh|console|activate`. All of it works
  without sudo: the VM runs as a launchd user agent, never at login.
- macOS activation deploys to it over SSH when it is running, and skips
  quietly when it is not — a later start boots the new configuration anyway.
  If the guest is up but the deploy fails, activation warns loudly instead of
  failing; `linux-vm restart` always converges.
- A guest that has been up across several Mac rebuilds cannot see store paths
  built since it booted — its view of the shared lower store froze at boot.
  Activation therefore pushes the new closure's missing paths into the guest's
  own store with `nix copy` before switching. The why lives in
  ./linux-vm/default.nix.

## Reading a change before activating it

Never activate without reading the diff first.

- `./rebuild diff` lists the packages a switch would add, drop or move.
- `./rebuild diff-drv` says *why* a derivation differs, for when no version
  moved and everything rebuilt anyway.

Those two are the MacBook wrapper. hetztop has no equivalent script, so the
same two questions are asked by hand — build without activating, then diff the
result against the running system:

```sh
nix-build . --attr hetztop.config.system.build.toplevel --out-link /tmp/next
nix run --file . pkgs.nvd -- diff /run/current-system /tmp/next
nix run --file . pkgs.nix-diff -- --environment --skip-already-compared \
  --word-oriented --context 4 /run/current-system /tmp/next
```

Read both. nvd answers "what packages moved", and it is blind to a package
whose *contents* changed while its version did not — which is exactly what a
local-checkout input override does. nix-diff is what catches that. Worth
checking beyond either tool, since neither reports it:

```sh
diff -rq /run/current-system/etc /tmp/next/etc     # /etc, incl. sudoers
diff <(ls /run/current-system/etc/systemd/system) \
     <(ls /tmp/next/etc/systemd/system)            # units added or removed
readlink -f /run/current-system/kernel /tmp/next/kernel   # same kernel?
```

Then activate with `ai-rebuild`, no sudo in front of it. It evaluates and
builds as the calling user, so it shares that user's fetcher cache, and
elevates once at the end for the profile flip and the switch. It is NOPASSWD
for `lillecarl` on both machines that run agents — see
`hosts/hetztop/ai-rebuild.nix` and `hosts/macbook/ai-rebuild.nix`, and read
either grant as full root rather than narrow root. `ai-rebuild-pynixd` is the
same switch routed through the pynixd store.

## Version Control

This repo uses **jj (Jujutsu)** as its VCS. Always use jj commands instead of git.

- Load the **jj** skill before performing any version control operations
- Use `jj --no-pager` for all jj commands to avoid pager issues
- Prefer `jj commit -m "msg"` over `jj describe` when finishing a task
- Split a mixed working copy with `jj split <paths> -m '...'`, repeated. For
  finer-than-file granularity there is a `jj-hunk` CLI on PATH, documented by
  `references/jj-hunk.md` inside the jj skill. There is no separate jj-hunk
  *skill* to load, which an earlier version of this list claimed.
- Never use `git` directly — use jj equivalents instead

That last rule is enforced, not merely advised. `home/claude/skills/jj-worktrees`
installs a PreToolUse hook that denies any git command outside a small
read-only allowlist, whenever the working directory is a jj repo. Three things
follow from how it decides:

- It is deliberately fail-open. No `jj` on PATH, or a directory that is not a
  jj repo, both mean the command goes through. The ban applies *inside* jj
  repos, not everywhere.
- `jj git push` and friends are exempt, including behind jj's own global
  options (`jj --no-pager git fetch`). If a command you expect to be allowed
  gets denied, treat that as a hook bug rather than something to route around.
- It parses the command into shell words and only looks at words in *command
  position*, so text that merely mentions the tool — a commit message, a
  heredoc body, a grep pattern — is not an invocation. Nested shell is still
  caught, because `sh -c`, `$(...)`, backticks and prefix runners like `sudo`
  and `env` are each handled explicitly.
- A false positive costs more than a false negative, and every doubt is
  resolved that way. It guards against forgetting which VCS this repo uses,
  not against a determined caller — anything that cannot be lexed is allowed
  rather than blocked.

The hook is built by `home/agents.nix` and installed as `jj-block-git-write`,
so editing its script needs a rebuild to take effect — unlike the rest of
`home/claude/skills/`, which is an out-of-store symlink and applies at once.