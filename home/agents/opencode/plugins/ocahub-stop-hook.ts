import type { Plugin } from "@opencode-ai/plugin"

// The ocahub stop hook. An ask owes a reply before the session goes idle;
// opencode cannot veto idle, so on session.idle this plugin re-prompts the
// session with whatever the hub still owes. The model then answers via
// agent_reply. After three nudges at an unchanged ask set it gives up and
// logs, so a model that refuses to reply cannot spin forever.
//
// This plugin also OWNS the session's hub identity: it registers the real
// opencode session id (name, cwd, title) at session start, and the MCP server
// finds that registration through the hub (name + cwd, most recent). See
// pkgs/ocahub/src/ocahub/mcp_server.py.
//
// The registration is keptalive: the hub marks a session offline when no
// hello has arrived within its 120s TTL, and a hello that races the hub's
// own startup fails silently. So every session this instance has seen is
// re-helloed on an interval, with the session's current title (what /rename
// sets) fetched fresh each pass.

interface Ask {
  id: string
  from: string
  ts: number
}

const NUDGE_LIMIT = 3
const HELLO_EVERY_MS = 45_000

export const OcahubStopHook: Plugin = async ({ client, $, directory, worktree }) => {
  const NAME = process.env.OCAHUB_NAME || "opencode"
  const dir = worktree || directory
  let nudges: { key: string; count: number } | undefined
  const known = new Set<string>()
  let sweeping = false

  const sessionIDOf = (properties: any): string | undefined =>
    properties?.sessionID ?? properties?.info?.id

  const helloSession = async (sid: string) => {
    const got = await client.session.get({ path: { id: sid } }).catch(() => undefined)
    const info: any = (got as any)?.data ?? got
    const title = typeof info?.title === "string" ? info.title : ""
    // Bun escapes each interpolation as one argv element, so an interpolated
    // prefix string cannot be reused; each shape is spelled out.
    await (
      title
        ? $`ocac hello --name ${NAME} --session ${sid} --cwd ${dir} --title ${title}`
        : $`ocac hello --name ${NAME} --session ${sid} --cwd ${dir}`
    )
      .nothrow()
      .quiet()
  }

  const sweep = async () => {
    if (sweeping || known.size === 0) return
    sweeping = true
    try {
      for (const sid of known) {
        await helloSession(sid).catch(() => {})
      }
    } finally {
      sweeping = false
    }
  }
  const timer = setInterval(sweep, HELLO_EVERY_MS)
  timer.unref?.()

  const openAsks = async (sid: string): Promise<Ask[]> => {
    const p = await $`ocac asks --name ${NAME} --session ${sid}`.nothrow().quiet()
    if (p.exitCode !== 0) return []
    try {
      const parsed = JSON.parse(p.stdout.toString().trim())
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  return {
    event: async ({ event }) => {
      try {
        if (event.type === "session.created") {
          const sid = sessionIDOf(event.properties)
          if (!sid) return
          known.add(sid)
          await helloSession(sid)
          return
        }
        if (event.type !== "session.idle") return
        const sid = sessionIDOf(event.properties)
        if (!sid) return

        // Subagent child sessions are driven by their parent; nudging them
        // would inject a user message into someone else's flow.
        const got = await client.session.get({ path: { id: sid } }).catch(() => undefined)
        const info: any = (got as any)?.data ?? got
        if (info?.parentID) return

        const asks = await openAsks(sid)
        if (!asks.length) {
          nudges = undefined
          return
        }
        const key = JSON.stringify(asks.map((a) => a.id))
        if (nudges && nudges.key === key && nudges.count >= NUDGE_LIMIT) {
          await client.app
            .log({
              body: {
                service: "ocahub-stop-hook",
                level: "warn",
                message: `giving up: ${asks.length} ask(s) still unanswered after ${NUDGE_LIMIT} nudges`,
                extra: { sessionID: sid, asks: asks.map((a) => a.id) },
              },
            })
            .catch(() => {})
          return
        }
        nudges = { key, count: nudges && nudges.key === key ? nudges.count + 1 : 1 }
        const listing = asks
          .map((a) => `- reply_to ${a.id} (from ${a.from})`)
          .join("\n")
        await client.session
          .prompt({
            path: { id: sid },
            body: {
              parts: [
                {
                  type: "text",
                  text:
                    `You went idle owing ${asks.length} ocahub ask(s). ` +
                    `Answer each with agent_reply(reply_to=<id>) before stopping:\n${listing}\n` +
                    "If you no longer have the original message, call agent_inbox first.",
                },
              ],
            },
          })
          .catch(() => {})
      } catch {
        // The stop hook must never take the session down with it.
      }
    },
  }
}
