# greet: template Nix project

Reference layout for a project packaged with Nix. Works with and without
flakes; nothing is reachable only through a flake. Copy it, rename `greet`.

| file | role |
| --- | --- |
| `default.nix` | The real entry point. Wires `nix/` files to `pkgs`; defines nothing itself. |
| `flake.nix` | Wrapper: maps `default.nix` over systems. Owns the pins. |
| `flake.lock` | The one lock. Both entry points read it. |
| `nix/compat.nix` | Reads `flake.lock` without the flake evaluator (flake-compatish). |
| `nix/package.nix` | `callPackage`-able derivation. No pins, no `pkgs` argument. |
| `nix/overlay.nix` | Adds `greet` to a consumer's package set. |
| `nix/module.nix` | NixOS module. Builds from the consumer's `pkgs`. |
| `nix/shell.nix` | Dev shell, `callPackage`-able. |
| `nix/checks.nix` | Every check, as one attrset. Loaded with `callPackages`. |
| `shell.nix` | `(import ./. { }).shell`, for `nix-shell` and direnv. |

## Commands

```sh
nix build --file . greet
nix build --file . checks          # every check, flake-free
nix develop --file . shell
nix-shell
nix build .#default                # flake, same .drv as --file . greet
nix flake check
```

Inside a git repo that does not track these files, flake commands need
`path:$PWD` instead of `.`.

## Rules the layout encodes

- **`default.nix` first, and thin.** It takes `inputs`, `system` and `pkgs`,
  each defaulted, and maps files in `nix/` to outputs. A body longer than a
  `callPackage` line belongs in its own file. A consumer passes their own
  `pkgs` and gets one nixpkgs, not two.
- **The flake passes `inputs` and `system` only**, never
  `legacyPackages`: flake-compatish evaluates flake outputs impurely, and
  `legacyPackages` then reads `~/.config/nixpkgs`.
- **One lock.** `flake.lock` pins; `nix/compat.nix` reads it for
  non-flake evaluation (`import flake-compatish ../.`, in place). No npins
  or niv beside it. The `overriding self` warning is intended: `self` is
  the working directory, untracked files included, and not the git tree
  the flake evaluator copies.
- **Every flake output is a `default.nix` attribute or a plain file.**
  `overlays.default` and `nixosModules.default` point at the same files
  `default.nix` exposes as `overlay` and `nixosModule`.
- **`package.nix` is upstreamable in shape.** Explicit argument list, nothing
  pinned. Only `src` is local; nixpkgs would use a fetcher there.
- **`src` is a fileset**, not `./.`. Docs and `.nix` edits do not rebuild.
- **`import nixpkgs { config = { }; overlays = [ ]; }`.** Without the empty
  values, nixpkgs reads `~/.config/nixpkgs`.
- **An attrset of derivations loads with `callPackages`.** `callPackage`
  adds `override` and `overrideDerivation` to the set, and `nix flake check`
  rejects those as checks.
- **Checks cover the outputs**: version check in the build, a
  `passthru.tests` run, nixfmt, and an eval-only module test (about 2s).

## Measured

- `nix eval --file . greet.drvPath` equals
  `nix eval .#packages.x86_64-linux.default.drvPath` and
  `(import ./nix/compat.nix).impure.packages.default.drvPath`.
- A `__functor` `default.nix` breaks `nix build --file . greet`,
  `nix-build -A greet` and `--arg` ("should be a set but is a function").
  `callPackage ./. { }` on it silently ignores the caller's `pkgs`.
- An untracked file is visible through `inputs.self` of `nix/compat.nix`,
  and not through `getFlake "git+file://…?dir=…"`.
- Under flake-compatish, `NIXPKGS_CONFIG` with `allowUnfree = true` turns
  `legacyPackages.x86_64-linux.config.allowUnfree` true.
- Appending to a `.nix` file leaves `greet.drvPath` unchanged.
- Each check fails on its broken case: an unformatted file, and a module
  that drops the package from `systemPackages`.
- nixpkgs 26.11 throws on `x86_64-darwin`, so the systems list omits it.

## Open for iteration

- No VM test (`testers.runNixOSTest`); the module check is eval-only.
- No `passthru.updateScript`, no home-manager module, no multi-package scope.
