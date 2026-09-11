import type { Plugin } from "@opencode-ai/plugin"

// Blanket-deny gate for tools turned off by the tool-toggles TUI plugin.
//
// Disabled tools stay in the model's tool list on purpose: a model that
// cannot see a tool at all gets stuck with no way to adapt. Instead the
// toggle rules (stored in the session's permission ruleset as deny rules
// with pattern "**") leave the tool visible, and this gate answers every
// call to a disabled tool with a plain error the model can read. The
// "**" pattern also denies at the permission engine itself, so the tool
// stays blocked with a canned denial message even if this plugin fails to
// load.
//
// The session ruleset is read on every call: cheap local HTTP, always
// fresh. Subagent tool calls bypass tool.execute.before upstream
// (anomalyco/opencode#5894), so they are not gated here.

const EDIT_TOOLS = new Set(["edit", "write", "apply_patch"])
const READ_TOOLS = new Set(["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"])

function permissionKey(tool: string): string {
  if (EDIT_TOOLS.has(tool)) return "edit"
  if (READ_TOOLS.has(tool)) return "read"
  return tool
}

type Rule = { permission: string; pattern: string; action: "allow" | "deny" | "ask" }

type SessionInfo = { permission?: Rule[] }

export const ToolGate: Plugin = async ({ client }) => {
  return {
    "tool.execute.before": async (input) => {
      const key = permissionKey(input.tool)
      const res = await client.session.get({ path: { id: input.sessionID } })
      const rules = ((res?.data ?? res) as SessionInfo | undefined)?.permission ?? []
      const mine = rules.filter((rule) => rule.permission === key && (rule.pattern === "*" || rule.pattern === "**"))
      if (mine.at(-1)?.action !== "deny") return
      throw new Error(
        `The ${input.tool} tool is currently disabled by the user for this session. Do not retry it and do not work around it (no shell or script replacements); tell the user it is disabled and continue without it, or ask them to re-enable it.`,
      )
    },
  }
}
