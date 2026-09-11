import type { TuiPlugin, TuiPluginApi } from "@opencode-ai/plugin/tui"

// Session-scoped tool toggles. Opens a dialog from the command palette that
// turns tools on and off for the CURRENT session by appending permission
// rules ({permission, pattern: "*", action: deny|allow}) through the session
// update endpoint. Rules are findLast-wins, so re-enabling appends an allow
// rule. Tools hidden this way are removed from the model's tool list entirely
// (Permission.disabled + Permission.visibleTools), which is the point: a weak
// model never sees a tool it would misuse. Rules reset with the session.
//
// api.client is the v2 SDK: flat {sessionID} parameters, second options
// argument, {data} responses, and errors only thrown with throwOnError --
// without it a 404 comes back as an {error} envelope that looks like success.
// The update response carries the merged ruleset, so it is authoritative;
// state is applied optimistically and rolled back if the call fails.

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

type WithData<T> = { data?: T } & T

function currentSession(api: TuiPluginApi): string | undefined {
  const route = api.route.current
  return route.name === "session" ? route.params.sessionID : undefined
}

function unwrap<T>(response: WithData<T> | undefined): T | undefined {
  return response?.data ?? (response as T | undefined)
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

  let rules: Rule[] = []
  let busy = false

  try {
    const res = await api.client.session.get({ sessionID }, { throwOnError: true })
    const found = unwrap<{ permission?: Rule[] }>(res)?.permission
    rules = Array.isArray(found) ? found : []
  } catch (error) {
    api.ui.toast({ variant: "error", message: `Could not read session: ${error?.message ?? error}` })
    return
  }

  const render = () => {
    api.ui.dialog.replace(() =>
      api.ui.DialogSelect({
        title: "Tool access (this session)",
        options: TOOLS.map((key) => {
          const state = stateOf(rules, key)
          return {
            title: key,
            value: key,
            footer: state === "off" ? "disabled" : state === "on" ? "enabled" : "default",
          }
        }),
        onSelect: (option) => {
          void toggle(option.value as string)
        },
      }),
    )
  }

  const toggle = (key: string) => {
    if (busy) return
    busy = true
    const enable = stateOf(rules, key) === "off"
    const rule: Rule = { permission: key, pattern: "*", action: enable ? "allow" : "deny" }
    const previous = rules
    rules = [...rules, rule]
    render()

    void api.client.session
      .update({ sessionID, permission: [rule] }, { throwOnError: true })
      .then((res) => {
        const next = unwrap<{ permission?: Rule[] }>(res)?.permission
        if (Array.isArray(next)) rules = next
        api.ui.toast({ variant: "success", message: `${key} ${enable ? "enabled" : "disabled"} for this session` })
        render()
      })
      .catch((error) => {
        rules = previous
        api.ui.toast({ variant: "error", message: `Toggle failed: ${error?.message ?? error}` })
        render()
      })
      .finally(() => {
        busy = false
      })
  }

  render()
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
