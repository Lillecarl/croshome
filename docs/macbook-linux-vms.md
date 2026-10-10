# The Linux VMs on the MacBook

Read this when the work touches `hosts/macbook/vz-builder/` or
`hosts/macbook/linux-vm/`, or when a build needs to run on Linux from the Mac.
Every number here was measured, not read.

## The Linux builders on the MacBook

| | `nix.linux-vz-builder` | `nix.linux-builder` |
| --- | --- | --- |
| Hypervisor | Virtualization.framework (vzvm) | QEMU + HVF |
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

`hosts/macbook/vz-builder/` holds three files. `default.nix` is the nix-darwin
module, `vm.nix` is the vzvm runner, and `guest.nix` is a whole NixOS system.
`guest.nix` is aarch64-linux, so changing it means a Linux rebuild.

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
key="$(nix eval --raw --file . inputs.nixpkgs)/nixos/modules/profiles/keys/ssh_host_ed25519_key"
ssh -i "$key" -p 31122 builder@127.0.0.1 systemd-analyze blame
ssh -i "$key" -p 31122 root@127.0.0.1 systemctl poweroff   # beats waiting out the idle timer
```

Measured rather than read, and easy to get wrong:

- Inbound ssh goes over **vsock, not the network**: `vzvm` forwards a loopback
  TCP port into the guest's `vsock:22`, where `systemd-ssh-generator` serves
  `sshd-vsock.socket`. So the guest needs no resolvable name and no inbound IP —
  macOS bootpd serves no DNS in any case — and no mDNS registration exists to go
  stale across a restart. That is the failure the old avahi setup papered over.
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

### Sharing the host store needs a case-sensitive /nix

`hostStore = "overlay"` exposes the host `/nix/store` to the guest through
virtiofs, and the guest reads it in place. That works only while `/nix` is
case-sensitive. On a case-insensitive store Nix mangles colliding names
(`use-case-hack`), and the guest reads the mangled names.

Activation probes `/nix` in `preActivation`, nix-darwin's first step, and
aborts with a message when the probe fails. `"substituter"` and `"off"` copy
paths into the guest instead, so they need no case-sensitive store.

### Deferred: a store that runs on a disk image

A Mac with a case-insensitive `/nix` should still run the builder. The plan is
a base image plus a differential overlay, so the guest's store is its own and
does not depend on the host's.

Virtualization.framework cannot do that yet. It attaches raw disk images only;
qcow2 and backing files are unsupported. Apple's macOS 27 `DiskImageKit` adds
the missing piece -- stacked images with a read-only base, a cache layer and
copy-on-write overlay layers -- but it is beta.

Two substitutes work today:

- a read-only base image attached as a read-only virtio-blk disk, overlaid in
  the guest by the existing writable disk; or
- an APFS clone (`cp -c`) of a base image per start, a differential overlay at
  the filesystem level that needs no guest change.

Both share one trap: an image built by copying host-store files inherits the
host's mangling. De-mangling needs a NAR round trip, which
`nixos/lib/make-squashfs.nix` does not do.

### The upstream vzvm builder, in parallel

`hosts/macbook/vz-builder-upstream/` runs upstream's builder
(`pkgs.darwin.linux-builder-vz`, driven by `vzvm`) beside ours, to compare
them. Both now run on `vzvm`; the difference is the store. This one keeps its
own store on an erofs image plus a data disk, so it does not need a
case-sensitive `/nix`.

Upstream runs it always-on. This module starts it on demand, and vzlink drives
it the same way as ours: launchd listens on 31023, `vzlink-proxy` splices to
`vzvm` on 31024, and `vzlink-supervisor` waits on the guest's readiness agent
(forwarded on 31025) and stops the VM after 60s idle. `stopMode` is
`graceful` here, because the disk persists; measured, ~2.0s.

Two changes to upstream's guest, both through its `modules` list:

- **The root is the persistent disk**, not a tmpfs. On upstream's tmpfs root
  the Nix database (`/nix/var`) was lost at every boot while the store layer
  on the disk persisted, so the guest forgot what it had built. Measured: a
  path built before an idle stop is still valid after the next boot. The disk
  is `vzvm-builder-root.img`; the older `vzvm-builder.qcow2` holds the
  previous layout and is unused.
- **The erofs store image is pre-built.** Upstream builds it in the run script,
  because a derivation would need this very builder. Activation kicks a launchd
  job (`vzvm-builder-vm-prewarm`, log `prewarm.log`) that builds it in the
  background, never blocking or failing the switch; the run script still builds
  it when the job has not. Measured: 13s for a 1.2 GB image.

Cold build through it: ~12s, of which ~3.7s is sshd starting after the
readiness agent in upstream's guest. Its ssh alias is `linux-builder-vz`, and
its images, key share and logs live in `/var/lib/vzvm-builder/`.

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

