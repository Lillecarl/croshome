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