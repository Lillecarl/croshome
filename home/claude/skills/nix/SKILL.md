---
name: nix
description: Running the Nix CLI — building, evaluating, searching, running packages, dev shells, hashes and store queries. Use whenever you are about to type a `nix` command, or reaching for `nix-build`, `nix-shell`, `nix-env` or `nix-instantiate`. Covers the non-flake `--file` invocation form this machine uses and the system nixpkgs at /etc/nixpkgs. For writing Nix code rather than running it, use the nix-language skill.
---

# The Nix CLI

Five rules first. They cover what goes wrong most often.

## 1. Always `nix`, never the legacy binaries

| use | not |
| --- | --- |
| `nix build --file . <attr>` | `nix-build -A <attr>` |
| `nix eval --file . <attr>` | `nix-instantiate --eval -A <attr>` |
| `nix run --file . <attr>` | — |
| `nix shell --file . <attr>` | `nix-env -i` |
| `nix develop --file .` | `nix-shell` |
| `nix profile` | `nix-env` |
| `nix store gc` | `nix-collect-garbage` |

Spell flags long: `--file`, not `-f`. Four legacy commands have no working nix3
equivalent and stay: `nix-store --gc --print-roots`, `nix-store --query
--references`, `nix-env -p /nix/var/nix/profiles/system --set`, and package
search — see the bottom of this file.

## 2. The non-flake invocation form

```
nix <subcommand> <options> --file <path> <attrpath>
```

That is the shape for every subcommand. `--file` selects the expression;
`<attrpath>` selects inside it. No `#`, no `.#`, no flake reference.

```sh
nix build --file . dynhetz.config.system.build.toplevel
nix eval  --file . --raw dynhetz.config.networking.hostName
nix run   --file /etc/nixpkgs ripgrep -- --version
```

## 3. `/etc/nixpkgs` is the system nixpkgs

It is what `NIX_PATH` points at (`nixpkgs=/etc/nixpkgs`), and it is the tree
this machine actually builds from. Read it instead of guessing at an option, a
setup hook or the shape of a package, and instead of cloning nixpkgs — a clone
drifts from the tree that builds the system.

```sh
grep -rl pytestCheckHook /etc/nixpkgs/pkgs/development/python-modules | head
nix eval --file /etc/nixpkgs --apply 'p: (p {}).lib.version'
```

It is a store path, so it is read-only, and it moves when the lock moves.

## 4. Run a package without installing it

```sh
nix run   --file /etc/nixpkgs <package> -- <command args>
nix shell --file /etc/nixpkgs <package> --command <cmd>
```

`--` separates the package from the arguments you pass it. `nix shell` is the
one to use when you need several packages on `PATH`, or when the binary name
differs from the attribute name.

## 5. Prefer non-flake

Write `default.nix` / `shell.nix`, not `flake.nix`. Flakes copy the source into
the store and evaluate from there, which is slower, and they pin `pkgs` for the
consumer instead of letting them supply it. Use `flake.lock` plus flake-compat
if you want the lockfile without the rest.

The entry point that gives a consumer the choice:

```nix
{ pkgs ? import <nixpkgs> { } }:
```

See the `nix-language` skill for why that default matters and what to write
instead of it inside a module.

---

## Evaluating

`--file` implies `--impure`. Use `--impure` explicitly with `--expr` when the
expression reads `<nixpkgs>`, an env var or an arbitrary path.

```sh
nix eval --file . <attr> --json      # parseable
nix eval --file . <attr> --raw       # unquoted string
nix eval --file . <attr> --read-only # skip instantiation, faster
```

`--apply` takes a lambda receiving the file's top-level value. A `default.nix`
that is a function must be called before you can look inside it:

```sh
nix eval --file . --apply 'x: builtins.attrNames (x {})' --json
nix eval --file . --apply 'x: let d = x {}; in { inherit (d.package) pname version; }' --json
nix eval --file . package.meta.position --json   # "file:line" where it is defined
```

## Building

```sh
nix build --file . <attr>                          # ./result symlink
nix build --file . <attr> --out-link /tmp/next     # name the symlink
nix build --file . <attr> --print-out-paths --no-link
nix build --file . <attr> --dry-run                # what would build
nix build --file . <attr> --print-build-logs       # logs as it goes
```

A build that fails and a build you want to read again both go through
`nix log <store-path>`.

## Finding a hash

```sh
nix build --impure --expr 'let pkgs = import <nixpkgs> {}; in pkgs.fetchFromGitHub {
  owner = "OWNER"; repo = "REPO"; rev = "v1.0.0"; hash = pkgs.lib.fakeHash;
}' 2>&1 | grep -E "specified:|got:"
```

The `got:` line is the answer. Same trick for `fetchurl`, `fetchFromGitLab` and
the rest. In `fetchFromGitHub`, `rev` takes a plain tag — `rev = "v1.0.0"`,
never `refs/tags/v1.0.0`.

To discover a fetcher's arguments (`true` = has a default, `false` = required):

```sh
nix eval --impure --expr 'let pkgs = import <nixpkgs> {}; in pkgs.fetchFromGitHub.__functionArgs' --json
```

## Reading a package's source

The exact source a package was built from, with its patches applied by
nixpkgs' own fetcher:

```sh
nix build --file /etc/nixpkgs <package>.src --no-link --print-out-paths
```

Usually the result is a directory you can read straight away. Occasionally it
is a tarball, because the package fetches a release archive rather than a
repository — measured: `ripgrep.src` is a directory, `hello.src` is a
`.tar.gz`. Test before you `cd` into it:

```sh
src=$(nix build --file /etc/nixpkgs hello.src --no-link --print-out-paths)
[ -d "$src" ] || { d=$(mktemp -d); tar -xf "$src" -C "$d"; src=$d; }
```

`$src` is a directory either way after that. Point `mktemp` at your scratchpad
(`TMPDIR=…`) if you want the extraction to land there.

This beats cloning upstream for almost every "what does this actually do"
question: it is the revision that built the binary on this machine, not
whatever `main` says today. Works for language package sets too —
`python3Packages.anyio.src` is how you read anyio's implementation.

## Dev shells

```sh
nix develop --file .
nix develop --file . --command <cmd>   # non-interactive; plain develop wants a TTY
```

## Store queries

| Command | Purpose |
|---------|---------|
| `nix path-info --json --json-format 2 <installable>` | store paths without building |
| `nix derivation show <installable>` | the derivation as JSON |
| `nix why-depends <pkg> <dep>` | why one depends on the other |
| `nix store ls <path>` / `nix store cat <path>` | look inside a store path |
| `nix copy --to <store> <path>` | move a closure |
| `nix hash file\|path <path>` | hash something |
| `nix hash convert --from <fmt> --to <fmt> <hash>` | change hash format |
| `nix store gc` | collect garbage |

## Searching for a package

`nix search --file` does not work against nixpkgs. It evaluates the attrpath
from the file's root without calling it, and `/etc/nixpkgs/default.nix` is a
function, so it stops at `'' is not an attribute set`. No attrpath fixes that.

Two things that do work:

```sh
nix-env --query --available --attr-path --file /etc/nixpkgs <regex>  # ~1 min, noisy on stderr
grep -rl '<name>' /etc/nixpkgs/pkgs/by-name | head
```

A fourth legacy exception, then, alongside the three above. Redirect stderr:
the deprecation warnings drown the result.

## Reference

`man -k nix3` lists every subcommand; `nix <cmd> --help` explains one.

`builtins.*` are available unprefixed inside a Nix expression. The full list is
`nix eval --expr 'builtins.attrNames builtins' --json`, which beats a table
that goes stale.
