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

x86_64-linux works only on the VZ one. Rosetta-for-Linux is a
Virtualization.framework feature, unreachable from QEMU at any configuration.

The QEMU one is disabled, not deleted — it is the way back if the VZ builder
breaks. **Fixing the VZ *guest* means turning `nix.linux-vz-builder.enable` off
in the same edit.** The guest is an aarch64-linux system, so building a changed
one needs a Linux builder: that is the deadlock, and it is not hypothetical.
See the commit that added the activation check.

Using the VZ builder: build anything. Connecting to 127.0.0.1:31122 starts it.
`hosts/macbook/vz-builder/guest.nix` is a whole NixOS system, so changing it
means an aarch64-linux rebuild.

### Running Linux commands: `vzrun`

`vzrun` runs a command in the builder — Linux-only work a build sandbox cannot
do: a network, a real `/proc`, a mount namespace, or a shell.

```sh
vzrun uname -m                 # aarch64
vzrun --root mount             # root in the guest; see below
vzrun                          # interactive shell
```

It connects to the same port a distributed build does, so it starts the VM and
feeds the idle watchdog the same way. An open session holds the VM up; closing
it starts the 60s clock. Measured: **7.9s cold** (the guest booting) and **63ms
warm**, because ssh multiplexing keeps one connection for 30s.

**`/nix/store` in the guest is this Mac's store**, through the overlay, so a
Linux binary built here just runs:

```sh
nix build --file . <attr> && vzrun ./result/bin/<x>
```

`vzrun` starts in `$PWD` when the guest has a directory by that name — which is
why the line above works — and falls back to `/nix/.rw-store/build`. Nothing
else of this Mac is visible; there is no `$HOME` share.

Scratch lives on the guest's own ext4, not on a virtiofs share of a host
directory. That share is why **meson reported clock skew**: the guest runs
~70ms behind macOS, so a file written through virtiofs came back with an mtime
in the guest's future. The read-only store share is the only virtiofs left in a
build's path and cannot skew anything — Nix normalises store timestamps to the
epoch (`mtime=1`).

A store path added on the Mac **while the VM runs** behaves two ways at once,
both measured against one VM instance:

| | new path added mid-run |
| --- | --- |
| `vzrun ls $p/bin` | works -- overlayfs reads the lower layer live |
| `vzrun nix path-info $p` | "this path will be fetched" -- not valid |

The daemon holds the lower store's SQLite open as `immutable`: its view of the
*database* freezes at boot, its view of the *files* does not. `vzrun` is
unaffected — it goes to the filesystem and never asks Nix. A build inside the
guest may refetch what the Mac already has. Restarting re-reads the database.

Access:

- `nix.linux-vz-builder.authorizedKeys` is what makes `vzrun` work, and is a
  separate mechanism from `debugAccess`. The builder key in `/etc/nix` is
  `root:nixbld 0600`, so it is no answer for an ordinary user.
- Those keys are **global** in the guest's sshd, not per user, so they log in
  as `root` too. That is `--root`. It adds no reachable privilege: the guest is
  disposable, reachable only from this Mac, and `builder` is a trusted Nix user
  that can already run anything there by submitting a derivation.
- `nix.linux-vz-builder.debugAccess` (off by default) authorises the keypair
  nixpkgs ships for its builder VM — world-readable, so already public — for
  profiling:

```sh
key="$(nix eval --raw -f . inputs.nixpkgs)/nixos/modules/profiles/keys/ssh_host_ed25519_key"
ssh -i "$key" -p 31122 builder@127.0.0.1 systemd-analyze blame
ssh -i "$key" -p 31122 root@127.0.0.1 systemctl poweroff   # beats waiting out the idle timer
```

Measured rather than read, and easy to get wrong:

- macOS **bootpd serves no DNS**. The DHCP hostname lands in
  `/var/db/dhcpd_leases` and resolves nowhere. mDNS works, so the guest runs
  avahi and answers at `vzbuilder.local`.
- A macOS **unix socket path cannot exceed 104 bytes**, which the scratchpad
  directory alone can exceed.
- `unix://` **cannot retrieve build results** from a daemon in a VM: it asks
  the daemon whether a path is valid, then reads the contents off the *local*
  filesystem, so builds succeed and nothing reads back. Use `ssh-ng://`.
  Reported as Lillecarl/nix#307.
- **`--cores` from a host client does not reach the guest daemon.** `--cores 3`
  on a build farmed out to the VM still logged `build flags: -j15`. Only
  `nix.settings.cores` in `guest.nix` changes it. This cost a wrong hypothesis
  chasing an OOM in `cc1plus` on `eval.cc` under `-flto`; the fix was swap, not
  parallelism.
- A guest change takes effect only once the VM has **restarted onto it**.
  Measuring a still-resident VM after a rebuild reads as confirmation and is
  not. Activation now stops a stale VM for this reason.

### The persistent Linux VM

`hosts/macbook/linux-vm` is a second guest on the same Virtualization.framework
stack: persistent root disk, started and stopped by hand, deliberately not a
builder. It hosts kernel-required workloads (Kubernetes and friends), defined
in its NixOS module like any other machine.

- `linux-vm start|stop|restart|status|ssh|console|activate`. No sudo needed —
  the VM runs as a launchd user agent, never at login.
- macOS activation deploys to it over SSH when it runs, and skips quietly when
  it does not; a later start boots the new configuration anyway. If the guest
  is up and the deploy fails, activation warns loudly rather than failing.
  `linux-vm restart` always converges.
- A guest up across several Mac rebuilds cannot see store paths built since it
  booted — its view of the shared lower store froze at boot. Activation
  therefore `nix copy`s the new closure's missing paths into the guest's own
  store before switching. Why: `hosts/macbook/linux-vm/default.nix`.

## Reading a change before activating it

Never activate without reading the diff first.

- `./rebuild diff` — packages a switch would add, drop or move.
- `./rebuild diff-drv` — *why* a derivation differs, for when no version moved
  and everything rebuilt anyway.

Both are the MacBook wrapper. The NixOS hosts have no equivalent script, so ask
the same two questions by hand: build without activating, then diff against the
running system.

```sh
nix-build . --attr <host>.config.system.build.toplevel --out-link /tmp/next
nix run --file . pkgs.nvd -- diff /run/current-system /tmp/next
nix run --file . pkgs.nix-diff -- --environment --skip-already-compared \
  --word-oriented --context 4 /run/current-system /tmp/next
```

Read both. nvd answers "what packages moved" and is blind to a package whose
*contents* changed while its version did not — exactly what a local-checkout
input override does. nix-diff catches that. Neither reports these:

```sh
diff -rq /run/current-system/etc /tmp/next/etc     # /etc, incl. sudoers
diff <(ls /run/current-system/etc/systemd/system) \
     <(ls /tmp/next/etc/systemd/system)            # units added or removed
readlink -f /run/current-system/kernel /tmp/next/kernel   # same kernel?
```

Then activate with `ai-rebuild`, no sudo in front of it. It evaluates and builds
as the calling user, sharing that user's fetcher cache, and elevates once at the
end for the profile flip and the switch. NOPASSWD for `lillecarl` on macbook,
hetztop and dynhetz — see each `hosts/*/ai-rebuild.nix`, and read the grant as
full root, not narrow root. `ai-rebuild-pynixd` (hetztop only) is the same
switch routed through the pynixd store.

## Version Control

This repo uses **jj (Jujutsu)**. Never use `git` directly.

- Load the **jj** skill before any version control operation.
- `jj --no-pager` on every jj command, to avoid the pager.
- Prefer `jj commit -m "msg"` over `jj describe` when finishing a task.
- Split a mixed working copy with `jj split <paths> -m '...'`, repeated. For
  finer-than-file granularity use the `jj-hunk` CLI on PATH, documented in
  `references/jj-hunk.md` inside the jj skill. There is no jj-hunk *skill*.

The git ban is enforced, not merely advised. `home/claude/skills/jj-worktrees`
installs a PreToolUse hook that denies any git command outside a small
read-only allowlist, whenever the working directory is a jj repo. How it
decides:

- Fail-open by design. No `jj` on PATH, or a directory that is not a jj repo,
  and the command goes through. The ban applies *inside* jj repos, not
  everywhere.
- `jj git push` and friends are exempt, including behind jj's own global
  options (`jj --no-pager git fetch`). A denial you did not expect is a hook
  bug, not something to route around.
- It lexes the command and reads only words in *command position*, so a commit
  message, heredoc body or grep pattern that mentions git is not an invocation.
  Nested shell is still caught: `sh -c`, `$(...)`, backticks and prefix runners
  like `sudo` and `env` are each handled explicitly.
- Doubt resolves to allowing, because a false positive costs more than a false
  negative. Anything unlexable goes through. It guards against forgetting which
  VCS this repo uses, not against a determined caller.

`home/agents.nix` builds the hook and installs it as `jj-block-git-write`, so
editing its script needs a rebuild — unlike the rest of `home/claude/skills/`,
an out-of-store symlink that applies at once.