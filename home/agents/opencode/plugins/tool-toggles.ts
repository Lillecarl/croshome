import type { TuiPlugin, TuiPluginApi } from "@opencode-ai/plugin/tui"

// Session-scoped tool toggles. Opens a dialog from the command palette that
// turns tools on and off for the CURRENT session by appending permission
// rules ({permission, pattern: "*", action: deny|allow}) through the session
// update endpoint. Rules are findLast-wins, so re-enabling appends an allow
// rule. Tools hidden this way are removed from the model's tool list entirely
// (Permission.disabled + Permission.visibleTools), which is the point: a weak
// model never sees a tool it would misuse. Rules reset with the session.
//
// Deliberately palette-only: a default keybind needs the @opentui/keymap
// Binding shape, which is not importable from a plugin. The user can still
// reach it in two keystrokes from the command palette.

const CMD = "tools.toggle"

// Permission keys, not tool ids: edit covers edit/write/apply_patch and read
// covers read plus the MCP resource tools (Permission.disabled's mapping).
const TOOLS = [
  "bash",
  "edit",
  "read",
  "glob",
  "grep",
  "task",
  "skill",
  "todowrite",
  "question",
  "webfetch",
  "websearch",
]

type Rule = { permission: string; pattern: string; action: "allow" | "deny" | "ask" }

type SessionInfo = { permission?: Rule[] }

function currentSession(api: TuiPluginApi): string | undefined {
  const route = api.route.current
  return route.name === "session" ? route.params.sessionID : undefined
}

function stateOf(rules: Rule[] | undefined, key: string): "off" | "on" | "default" {
  const mine = (rules ?? []).filter((rule) => rule.permission === key && rule.pattern === "*")
  const action = mine.at(-1)?.action
  if (action === "deny") return "off"
  if (action === "allow") return "on"
  return "default"
}

async function show(api: TuiPluginApi) {
  const sessionID = currentSession(api)
  if (!sessionID) {
    api.ui.toast({ variant: "info", message: "Open a session first — tool toggles are per session" })
    return
  }

  let busy = false

  const render = (rules: Rule[] | undefined) => {
    api.ui.dialog.replace(() =>
      api.ui.DialogSelect({
        title: "Tool access (this session)",
        options: TOOLS.map((key) => {
          const state = stateOf(rules, key)
          return {
            title: key,
            value: key,
            footer:
              state === "off"
                ? "disabled"
                : state === "on"
                  ? "enabled"
                  : "default",
            onSelect: () => toggle(key, state),
          }
        }),
        onSelect: (option) => {
          const key = option.value as string
          const state = stateOf(rules, key)
          void toggle(key, state)
        },
      }),
    )
  }

  const toggle = (key: string, state: "off" | "on" | "default") => {
    if (busy) return
    busy = true
    const enable = state === "off"
    const body = { permission: [{ permission: key, pattern: "*", action: enable ? "allow" : "deny" }] }
    void api.client.session
      .update({ path: { id: sessionID }, body } as never)
      .then((info) => {
        const next = (info as { data?: SessionInfo; permission?: Rule[] })
        const rules = next?.data?.permission ?? next?.permission
        api.ui.toast({
          variant: "success",
          message: `${key} ${enable ? "enabled" : "disabled"} for this session`,
        })
        render(rules)
      })
      .catch((error) => {
        api.ui.toast({ variant: "error", message: `Toggle failed: ${error?.message ?? error}` })
        render(undefined)
      })
      .finally(() => {
        busy = false
      })
  }

  try {
    const info = (await api.client.session.get({ path: { id: sessionID } })) as unknown
    const wrapped = info as { data?: SessionInfo; permission?: Rule[] }
    render(wrapped?.data?.permission ?? wrapped?.permission)
  } catch (error) {
    api.ui.toast({ variant: "error", message: `Could not read session: ${error?.message ?? error}` })
  }
}

const tui: TuiPlugin = async (api) => {
  api.keymap.registerLayer({
    commands: [
      {
        name: CMD,
        title: "Tools: enable/disable tools",
        desc: "Toggle tool access for the current session",
        category: "Session",
        namespace: "palette",
        run() {
          void show(api)
        },
      },
    ],
    bindings: api.tuiConfig.keybinds.gather(CMD, [CMD]),
  })
}

// Path plugins must export an id (resolvePluginId rejects file plugins
// without one, and the failure only reaches the TUI's stderr).
export default { id: "tools-toggle", tui }
