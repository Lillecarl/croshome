// Loads the project's direnv environment into every shell command, and lets
// the agent refresh it -- including variables the environment stops setting.
//
// Why: opencode spawns each bash command as a fresh child of the server
// process, so commands inherit process.env. Running `direnv exec . cmd` per
// command re-evaluates the rc every time (slow for nix-based environments).
// Applying `direnv export json` to process.env pays evaluation once, and
// again only on demand.
//
// Tracking removals works through direnv's own bookkeeping, and only through
// it. `direnv export` reverts the caller's environment using the DIRENV_DIFF
// variable before evaluating the rc (internal/cmd/cmd_export.go), then emits
// a diff between the CALLER'S actual environment and the freshly evaluated
// one -- so anything our copy of the environment still carries but the rc no
// longer produces arrives explicitly marked for removal. In the json format
// removals are entries whose value is null (ShellExport.Remove encodes them
// as nil pointers). That has two consequences the code must respect:
//
//   1. DIRENV_* bookkeeping variables must be applied to process.env along
//      with everything else, or the next export cannot revert and stale
//      values survive every reload.
//   2. Null-valued entries must translate into deletions, not assignments.
//
// With that, plain `direnv export json` on each reload is sufficient; no
// `direnv exec`, no pristine-environment tricks.
//
// Costs one direnv evaluation at startup and one per explicit reload, zero
// per command. The .envrc must be allowed with `direnv allow`; the plugin
// never allows files itself.
//
// nix-direnv caveat: it caches the built profile in .direnv/ and serves it
// until a watched file is newer than the cache. Changes direnv cannot see --
// rebuilt local native code, collected garbage, hand-built store paths -- do
// not invalidate anything, so a reload then reports no changes. The escape
// hatches are `direnv reload` (touches .envrc, which is itself a watched
// file, thereby invalidating the cache) or the stronger
// `_nix_direnv_force_reload=1 direnv exec . true`, which is what nix-direnv's
// own nix-direnv-reload script runs. The tool surfaces both in its description
// and on the no-changes reply.
//
// No runtime bare-specifier imports ("@opencode-ai/plugin"). Plugin discovery
// follows the home-manager symlink into this repo, where no node_modules chain
// exists, so a runtime import fails to resolve and the plugin silently never
// loads. Type-only imports and node: builtins are fine.
import type { Plugin } from "@opencode-ai/plugin"

// Mirrors direnv's ShellExport: string sets the variable, null removes it.
type DirenvDelta = Record<string, string | null>

type EvalResult =
  | { kind: "ok"; delta: DirenvDelta }
  | { kind: "missing" }
  | { kind: "blocked" }
  | { kind: "error"; message: string }

const listKeys = (keys: string[], cap = 15) =>
  keys.length <= cap ? keys.join(", ") : `${keys.slice(0, cap).join(", ")} (+${keys.length - cap} more)`

export const Direnv: Plugin = async ({ client, $, directory }) => {
  // What the last application put into or removed from process.env, for
  // classifying the next reload's report.
  let applied: DirenvDelta = {}
  let envrcDir: string | null = null

  const note = async (level: "debug" | "info" | "warn" | "error", message: string) => {
    await client.app.log({ body: { service: "direnv", level, message } }).catch(() => {})
  }

  const findEnvrcDir = async (): Promise<string | null> => {
    const { dirname, join, sep } = await import("node:path")
    const { existsSync } = await import("node:fs")
    let current = directory
    while (true) {
      if (existsSync(join(current, ".envrc"))) return current
      if (current === "/" || !current.includes(sep)) return null
      const parent = dirname(current)
      if (parent === current) return null
      current = parent
    }
  }

  const evaluate = async (): Promise<EvalResult> => {
    try {
      const dir = await findEnvrcDir()
      if (!dir) return { kind: "missing" }
      envrcDir = dir
      const out = await $`direnv export json`.cwd(dir).quiet().text()
      return { kind: "ok", delta: out.trim() ? (JSON.parse(out) as DirenvDelta) : {} }
    } catch (e) {
      const stderr =
        typeof e === "object" && e !== null && "stderr" in e ? String((e as { stderr: unknown }).stderr ?? "") : ""
      if (stderr.includes("is blocked")) return { kind: "blocked" }
      return { kind: "error", message: stderr.trim() || String(e) }
    }
  }

  // Applies direnv's delta exactly as a hooked shell would: null deletes,
  // strings assign. Bookkeeping keys (DIRENV_DIFF and friends) pass through;
  // later exports need them to revert before re-evaluating.
  const applyDelta = (delta: DirenvDelta) => {
    const added: string[] = []
    const changed: string[] = []
    const removed: string[] = []
    for (const [k, v] of Object.entries(delta)) {
      const was = applied[k]
      if (v === null) {
        if (!(k in applied)) continue // removed something we never had
        delete process.env[k]
        if (!k.startsWith("DIRENV_")) removed.push(k)
      } else {
        if (!(k in applied)) {
          if (!k.startsWith("DIRENV_")) added.push(k)
        } else if (was !== v && !k.startsWith("DIRENV_")) changed.push(k)
        process.env[k] = v
      }
    }
    applied = { ...applied, ...delta }
    for (const k of Object.keys(applied)) if (applied[k] === null) delete applied[k]
    return { added, changed, removed }
  }

  const describe = (r: { added: string[]; changed: string[]; removed: string[] }) =>
    [
      r.added.length ? `added ${r.added.length}: ${listKeys(r.added)}` : "",
      r.changed.length ? `changed ${r.changed.length}: ${listKeys(r.changed)}` : "",
      r.removed.length ? `removed ${r.removed.length}: ${listKeys(r.removed)}` : "",
    ]
      .filter(Boolean)
      .join("; ")

  void (async () => {
    const r = await evaluate()
    if (r.kind === "missing") return
    if (r.kind === "blocked") {
      await note("warn", ".envrc is blocked; run `direnv allow` to enable it")
      return
    }
    if (r.kind === "error") {
      await note("error", `evaluation failed: ${r.message}`)
      return
    }
    const d = applyDelta(r.delta)
    await note("info", `loaded environment from ${envrcDir}/.envrc (${describe(d) || "no changes"})`)
  })()

  return {
    tool: {
      direnv_reload: {
        description:
          "Re-evaluate the project's .envrc via direnv and apply the fresh environment to subsequent shell " +
          "commands, including unsetting variables the environment no longer sets. Call this after the " +
          "environment's inputs change -- for example a rebuilt native library behind a nix dev shell, or " +
          "edited .envrc entries -- so builds and tests run against the current environment instead of a " +
          "stale one. Projects using nix-direnv serve a cached profile until a watched file changes; if this " +
          "reports no changes while you expected some, force the cache rebuild from the shell first -- " +
          "`_nix_direnv_force_reload=1 direnv exec . true` or `direnv reload` -- then call this again.",
        args: {},
        execute: async () => {
          const r = await evaluate()
          if (r.kind === "missing")
            return `No .envrc found in ${directory} or any parent up to the filesystem root. Nothing to reload.`
          if (r.kind === "blocked")
            return ".envrc is blocked. Ask the user to review it and run `direnv allow`; the plugin never allows files itself."
          if (r.kind === "error") return `direnv evaluation failed: ${r.message}`

          const d = applyDelta(r.delta)
          const summary = describe(d)
          await note("info", `reload: ${summary || "no changes"}`)
          if (!summary)
            return (
              "Environment re-evaluated; no variables changed. If you expected changes, the direnv cache " +
              "(nix-direnv serves a cached profile until a watched file changes) may be stale: run " +
              "`_nix_direnv_force_reload=1 direnv exec . true` or `direnv reload` via bash from the project " +
              "root, then call this tool again."
            )
          return `Environment reloaded from ${envrcDir}/.envrc. ${summary}. New values apply to subsequent shell commands.`
        },
      } satisfies {
        description: string
        args: Record<string, never>
        execute: (args: Record<string, never>, ctx: { directory: string }) => Promise<string>
      },
    },
  }
}
