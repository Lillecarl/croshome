# Filesets: the file-selection language

Filesets select a set of *files* (as opposed to revsets, which select commits). Used
as positional arguments to `jj split`, `jj diff`, `jj file list`, `jj restore`,
`jj absorb`, and others.

## File patterns

Bare `"path"` (no prefix) parses as `prefix-glob:` — a cwd-relative path prefix that
matches the file itself *and* recursively matches everything under it if it's a
directory.

| Pattern | Meaning |
|---|---|
| `cwd:"path"` | cwd-relative path prefix (file, or dir recursively) |
| `file:"path"` / `cwd-file:"path"` | exact cwd-relative file path (no recursion) |
| `glob:"pat"` / `cwd-glob:"pat"` | cwd-relative shell wildcard, non-recursive |
| `prefix-glob:"pat"` / `cwd-prefix-glob:"pat"` | like `glob:` but also matches recursively under matching dirs — `prefix-glob:"*.d"` = `glob:"*.d" | glob:"*.d/**"` |
| `root:"path"` | workspace-root-relative path prefix |
| `root-file:"path"` | exact workspace-root-relative file path |
| `root-glob:"pat"` | workspace-root-relative shell wildcard |
| `root-prefix-glob:"pat"` | like `root-glob:` but recursive under matching dirs |

Append `-i` for case-insensitive glob matching: `glob-i:"*.TXT"`.

Quoting: shell-quote the whole expression as usual. Inner quotes around the path are
only required if the expression contains an operator/function call, or the path has
whitespace/meta characters — e.g. `jj diff 'Foo Bar'` is fine unquoted-inside, but
`jj diff '~"Foo Bar"'` needs the inner quotes because of the `~`.

## Operators

Strongest to weakest binding:

| # | Operator | Meaning |
|---|---|---|
| 1 | `f(x)` | function call |
| 2 | `p:x` | pattern (see table above) or pattern alias |
| 3 | `~x` | everything except `x` |
| 4 | `x & y` | matches both | 
| | `x ~ y` | matches `x` but not `y` |
| 5 | `x \| y` | matches either |

## Functions

- `all()` — matches everything
- `none()` — matches nothing

## Aliases

```toml
[fileset-aliases]
LOCK = '**/Cargo.lock | **/package-lock.json | **/uv.lock'
```

## Examples

```bash
jj diff 'src'                          # everything under src/
jj diff '~glob:"*.lock"'               # exclude lockfiles
jj diff 'glob:"*.rs" ~ "**/test*"'     # rust files, excluding anything test-ish
jj file list 'src ~ glob:"**/*test*"'  # non-test files under src
jj split src/main.rs -m '...'          # put main.rs in the first (selected) commit
jj split '~src/wip.py' -m '...'        # put everything EXCEPT wip.py in the first commit
```
