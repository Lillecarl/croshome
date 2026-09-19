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

## This file

`CLAUDE.md` is a symlink to it. Claude Code reads only `CLAUDE.md`, so without
that link none of the rules below reach a Claude session — including the
advisor rule above, and the advisor is a Claude-only tool. opencode takes the
first of `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` that it finds and stops, so the
link adds nothing there. Do not delete it as a duplicate.

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
nix build --file . cros.activationPackage && ./result/activate
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

## The Linux VMs on the MacBook

Two guests on Virtualization.framework: `nix.linux-vz-builder`, the builder that
makes x86_64-linux reachable, and `hosts/macbook/linux-vm`, a persistent machine
for kernel-required workloads. `vzrun` runs a command in the builder.

`docs/macbook-linux-vms.md` has the rest, and it is worth reading before you
touch either: it holds measured facts that are easy to get wrong, including the
deadlock where fixing the guest needs a Linux builder to build the guest.

## Reading a change before activating it

Never activate without reading the diff first.

- `./rebuild diff` — packages a switch would add, drop or move.
- `./rebuild diff-drv` — *why* a derivation differs, for when no version moved
  and everything rebuilt anyway.

Both are the MacBook wrapper. The NixOS hosts have no equivalent script, so ask
the same two questions by hand: build without activating, then diff against the
running system.

```sh
nix build --file . <host>.config.system.build.toplevel --out-link /tmp/next
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

`claude-code` is intentionally unpinned so it always runs the latest version:
the overlay resolves `latest` from downloads.claude.ai at build time
(`pkgs/default.nix`). Every rebuild can bump it with no input change, so a
claude-code move in an otherwise unrelated diff is expected, not a leak.

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
editing its script needs a rebuild. So does every other file under
`home/claude/skills/`: each skill is a store path, linked one by one into
`~/.claude/skills` and `~/.gemini/skills`. Edit the skill in this repository,
never the link, and run `ai-rebuild` before you expect a session to see it.

The directory holding those links stays writable on purpose. Claude Code
writes its claude.ai skill sync into `~/.claude/skills/synced`, which is
gitignored here — it used to write itself into this repository, 4M of it.