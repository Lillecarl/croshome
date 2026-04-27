---
name: nix
description: Nix package manager and NixOS skill. Use for NixOS configuration, Nix flake development, package management, home-manager, nix-darwin, and declarative system management.
---

# Nix

Prefer nix3 commands (`nix build`, `nix eval`, etc.) over legacy `nix-*` commands. Only fall back to `nix-store`/`nix-instantiate` when no nix3 equivalent exists.

**Avoid flakes.** They copy sources to the store and eval from there, which is slow. Use `flake.lock` + `flake-compat` if you need lockfile pinning, but write `default.nix`/`shell.nix` — not `flake.nix`.

## nix3 Commands

| Command | Purpose |
|---------|---------|
| `nix build <installable>` | Build a derivation; creates `./result` symlink |
| `nix eval <installable>` | Evaluate a Nix expression |
| `nix path-info <installable>` | Show store paths without building |
| `nix derivation show <installable>` | Inspect derivation as JSON |
| `nix derivation add` | Add a store derivation |
| `nix copy --to <store> <path>` | Copy closures between stores |
| `nix run <installable>` | Build and run an app |
| `nix develop <installable>` | Enter a dev shell |
| `nix shell <installable>` | Run a command with packages in PATH |
| `nix search <installable> <regex>` | Search for packages |
| `nix edit <installable>` | Open Nix expression in `$EDITOR` |
| `nix log <installable>` | Show build log |
| `nix why-depends <pkg> <dep>` | Show why a package depends on another |
| `nix hash file <path>` | Hash a file |
| `nix hash path <path>` | NAR hash of a path |
| `nix hash convert --from <fmt> --to <fmt> <hash>` | Convert hash formats |
| `nix print-dev-env <installable>` | Print shell code to reproduce build env |
| `nix profile add <installable>` | Imperative profile management |
| `nix store gc` | Garbage collect unreachable paths |
| `nix store ls <path>` | List store path contents |
| `nix store cat <path>` | Cat a file from a store path |

## Legacy Commands (no nix3 equivalent)

- `nix-store --gc --print-roots | rg -v "proc|temp"` — list GC roots
- `nix-store --query --references <path>` — query dependencies
- `nix-store --realise <drv>` — realise a derivation

## Installable References

nix3 commands accept `<installable>` arguments. Without flakes:
- `--file release.nix attrpath` — build from a release Nix expression
- `<nixpkgs>` — uses nixpkgs channel
- `--attribute attrpath` — select attribute from default.nix
- Remote refs (`github:`, `path:`, etc.) require flakes

## Common Patterns

### Build a specific output
```sh
nix build .#packages.x86_64-linux.my-app
nix build .#nixosConfigurations.my-host.config.system.build.toplevel
```

### Check/evaluate without building
```sh
nix eval .#nixosConfigurations.my-host.config.networking.hostName --json
nix flake check --no-build
```

### Update flake inputs
```sh
nix flake lock --update-input nixpkgs   # single input
nix flake update                         # all inputs
```

### Fetch hash for a source
```sh
nix build --impure --expr 'let pkgs = import <nixpkgs> {}; in pkgs.fetchFromGitHub { owner = "OWNER"; repo = "REPO"; rev = "v1.0.0"; hash = pkgs.lib.fakeHash; }' 2>&1 | rg "specified:|got:"
```
The `got:` line shows the correct hash. Works for `fetchurl`, `fetchFromGitLab`, etc. too.

### Discover available fetchers and their arguments
```sh
# List all pkgs.fetch* fetchers
nix eval --impure --expr 'let pkgs = import <nixpkgs> {}; in builtins.attrNames (pkgs.lib.filterAttrs (name: _: pkgs.lib.strings.hasPrefix "fetch" name) pkgs)' --json

# Get a fetcher's function args (true = has default, false = required)
nix eval --impure --expr 'let pkgs = import <nixpkgs> {}; in pkgs.fetchFromGitHub.__functionArgs' --json
```

### Dev shells
```sh
nix develop                         # enter shell from flake.nix
nix develop .#my-shell              # specific devShell output
nix shell nixpkgs#python3 nixpkgs#jq  # ad-hoc shell with packages
```

## Reference

Use `man -k nix3` to list all nix3 subcommands, and `nix <cmd> --help` for details.

## nix eval --apply Patterns

Use `nix eval --file` with `--apply` to explore Nix expressions. The `--apply` lambda receives the file's top-level value. If it's a function, call it with `{}` (or pass arguments); if it's already an attrset, use it directly:

```sh
# default.nix is a function — call with {} to use defaults
nix eval --impure --file . --apply 'x: builtins.attrNames (x {})' --json

# Drill into nested attrs (e.g. package name/version)
nix eval --impure --file . --apply 'x: let d = x {}; in { name = d.package.pname; version = d.package.version; }' --json

# If default.nix is already an attrset, no need to call it:
# nix eval --impure --file . --apply 'builtins.attrNames' --json

# Find where a package is defined (returns "file:line")
nix eval --impure --file . package.meta.position --json
```

## Key Conventions

- Always use `--impure` with `nix eval` — allows reading env vars, `<nixpkgs>`, and arbitrary filepaths. `--file` implies `--impure`
- Always use `--json` with `nix eval` for parseable output; `--raw` for unquoted strings; `--read-only` to skip instantiation (faster)
- Use `nix flake show` to discover available outputs before targeting them
- Use `--dry-run` with `nix build` to see what would be built without building
- `nix build --print-out-paths --no-link` prints store path without creating symlink
- `nix build --out-link <name>` controls the result symlink name
- `nix eval --write-to <path>` writes strings/attrsets of strings to files
- `nix path-info` should use `--json --json-format 2`
- `nix develop --command <cmd>` — run a command in the dev shell (non-interactive; plain `nix develop` requires a TTY)
- For debugging builds: `nix log <store-path>` or `nix build --log-type flat`
- In `fetchFromGitHub`, `rev` can be a plain tag name like `rev = "v1.0.0"` — do NOT use `refs/tags/v1.0.0`

## Builtins Reference

Useful with `nix eval --apply` / `--expr`. All are available without `builtins.` prefix inside Nix expressions.

| | | | | |
|---|---|---|---|---|
| abort | add | addDrvOutputDependencies | addErrorContext | all |
| any | appendContext | attrNames | attrValues | baseNameOf |
| bitAnd | bitOr | bitXor | break | catAttrs |
| ceil | compareVersions | concatLists | concatMap | concatStringsSep |
| convertHash | currentSystem | currentTime | deepSeq | derivation |
| derivationStrict | dirOf | div | elem | elemAt |
| false | fetchGit | fetchMercurial | fetchTarball | fetchTree |
| fetchurl | filter | filterSource | findFile | flakeRefToString |
| floor | foldl' | fromJSON | fromTOML | functionArgs |
| genList | genericClosure | getAttr | getContext | getEnv |
| getFlake | groupBy | hasAttr | hasContext | hashFile |
| hashString | head | import | intersectAttrs | isAttrs |
| isBool | isFloat | isFunction | isInt | isList |
| isNull | isPath | isString | langVersion | length |
| lessThan | listToAttrs | map | mapAttrs | match |
| mul | nixPath | nixVersion | null | outputOf |
| parseDrvName | parseFlakeRef | partition | path | pathExists |
| placeholder | readDir | readFile | readFileType | removeAttrs |
| replaceStrings | scopedImport | seq | sort | split |
| splitVersion | storeDir | storePath | stringLength | substring |
| sub | tail | throw | toFile | toJSON |
| toPath | toString | toXML | trace | traceVerbose |
| true | tryEval | typeOf | unsafeDiscardOutputDependency | unsafeDiscardStringContext |
| unsafeGetAttrPos | warn | zipAttrsWith | | |