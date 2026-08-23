// Lets an agent manage its own context pressure with thresholds, plus a tool.
//
// Knobs (env-overridable), tuned for attention quality rather than window
// size -- long tails hurt even when they technically fit:
//
//   below MIN (15%)   -- the compact tool refuses; compacting an almost-empty
//                        context throws away more than it saves.
//   above HINT (35%)  -- user prompts carry a synthetic note telling the agent
//                        the percentage and to compact at a boundary. Rate
//                        limited: a new note only fires once usage has climbed
//                        HINT_STEP (1%, ~10k tokens on a 1M model) past the
//                        last one, so the band does not spam every prompt.
//   above FORCE (60%) -- compaction fires on its own at the next idle; the
//                        agent's cooperation is not required.
//
// Mechanics: a compaction is a user message carrying a `compaction` part. The
// run loop re-reads the message list at the top of every iteration and
// processes such parts as queued tasks. After summarizing, opencode injects a
// synthetic continue prompt, so the same run resumes on the compacted context.
//
// POST /session/:id/summarize queues exactly that and runs the loop. Awaiting
// it from inside a tool would deadlock: the server sees the session busy and
// waits for the current run, which waits for this tool. Fired without
// awaiting, the part lands while the model finishes its step and the running
// loop processes it next; if the run already ended, the endpoint starts a
// fresh run. Both orderings converge.
//
// No runtime bare-specifier imports ("@opencode-ai/plugin"). Plugin discovery
// follows the home-manager symlink into this repo, where no node_modules chain
// exists, so a runtime import fails to resolve and the plugin silently never
// loads. Type-only imports are erased at transpile, which is why retry-stop
// loads fine from the same directory.
import type { Plugin } from "@opencode-ai/plugin"

const num = (name: string, fallback: number) => {
  const v = Number(process.env[name])
  return Number.isFinite(v) && v > 0 ? v : fallback
}

const MIN_PCT = num("OPENCODE_COMPACT_MIN_PCT", 15)
const HINT_PCT = num("OPENCODE_COMPACT_HINT_PCT", 35)
const HINT_STEP_PCT = num("OPENCODE_COMPACT_HINT_STEP_PCT", 1)
const FORCE_PCT = num("OPENCODE_COMPACT_FORCE_PCT", 60)

type AssistantInfo = {
  id: string
  providerID: string
  modelID: string
  finish?: string
  error?: unknown
  mode?: string
  summary?: boolean
  tokens?: { input: number; output: number; reasoning: number; cache?: { read?: number; write?: number } }
}

export const SelfCompact: Plugin = async ({ client }) => {
  // The last build-mode assistant message a compaction was queued against.
  // Dedups repeated tool calls within a turn, and stops the forced path from
  // re-firing on the same high-water mark after a failed compaction.
  const compactedAt = new Map<string, string>()
  // Fill percentage at the last emitted hint, per session. A new hint waits
  // for HINT_STEP_PCT of climb past it; a descent (compaction happened)
  // rebaselines silently.
  const hintedAt = new Map<string, number>()
  // Set OPENCODE_SELF_COMPACT_DEBUG=1 to log evaluations.
  const debug = !!process.env.OPENCODE_SELF_COMPACT_DEBUG
  let providers: { all: Array<{ id: string; models: Record<string, { limit?: { context?: number } }> }> } | undefined
  let providersAt = 0

  const note = async (level: "debug" | "info" | "warn" | "error", message: string) => {
    if (level === "debug" && !debug) return
    await client.app.log({ body: { service: "self-compact", level, message } }).catch(() => {})
  }

  const isCompactionMsg = (info: AssistantInfo) => info.mode === "compaction" || info.summary === true
  const lastBuildAssistant = (messages: Array<{ info: AssistantInfo }>) =>
    [...messages].reverse().find((m) => m.info.role === "assistant" && m.info.finish && !isCompactionMsg(m.info))

  const contextTokens = async (providerID: string, modelID: string) => {
    if (!providers || Date.now() - providersAt > 600_000) {
      providers = (await client.provider.list({} as never)).data as typeof providers
      providersAt = Date.now()
    }
    return providers?.all.find((p) => p.id === providerID)?.models?.[modelID]?.limit?.context
  }

  // Context fill as opencode's own overflow check counts it: all four token
  // buckets of the last finished real assistant message, over the window size.
  const usage = async (sessionID: string) => {
    const messages = (await client.session.messages({ path: { id: sessionID } })).data ?? []
    const last = lastBuildAssistant(messages)
    if (!last) return undefined
    const t = last.info.tokens ?? { input: 0, output: 0, reasoning: 0 }
    const used = t.input + t.output + (t.cache?.read ?? 0) + (t.cache?.write ?? 0)
    const context = await contextTokens(last.info.providerID, last.info.modelID)
    if (!context) return undefined
    return { pct: (used / context) * 100, last }
  }

  const makePartID = () => {
    const now = BigInt(Date.now()) * BigInt(0x1000) + BigInt(Math.floor(Math.random() * 0x1000))
    const chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    let rand = ""
    for (let i = 0; i < 14; i++) rand += chars[Math.floor(Math.random() * chars.length)]
    return `prt_${now.toString(16).padStart(12, "0").slice(-12)}${rand}`
  }

  const queueCompaction = (sessionID: string, last: AssistantInfo) => {
    compactedAt.set(sessionID, last.id)
    hintedAt.delete(sessionID)
    void client.session
      .summarize({
        path: { id: sessionID },
        body: { providerID: last.providerID, modelID: last.modelID, auto: true },
      })
      .catch((e: unknown) => note("error", `summarize failed for ${sessionID}: ${e}`))
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        compactedAt.delete(event.properties.info.id)
        hintedAt.delete(event.properties.info.id)
        return
      }
      if (event.type !== "session.idle") return
      const sessionID = event.properties.sessionID

      let u: Awaited<ReturnType<typeof usage>>
      try {
        u = await usage(sessionID)
      } catch {
        return
      }
      if (!u || u.pct < FORCE_PCT) return
      if (compactedAt.get(sessionID) === u.last.info.id) return
      // Never compact out of an aborted or failed turn; the user may be
      // mid-thought and the retry-stop plugin owns error recovery.
      if (u.last.info.finish === "error" || u.last.info.error) return

      await note("info", `forcing compaction for ${sessionID} at ${u.pct.toFixed(0)}%`)
      queueCompaction(sessionID, u.last.info)
    },

    "chat.message": async (input, output) => {
      let u: Awaited<ReturnType<typeof usage>>
      try {
        u = await usage(input.sessionID)
      } catch {
        return
      }
      if (!u || u.pct < HINT_PCT) return
      const prev = hintedAt.get(input.sessionID)
      if (prev !== undefined) {
        if (u.pct < prev) {
          // Usage fell: a compaction happened. Rebaseline; the old hint text
          // is gone from the compacted context anyway.
          hintedAt.set(input.sessionID, u.pct)
          return
        }
        if (u.pct - prev < HINT_STEP_PCT) return
      }
      hintedAt.set(input.sessionID, u.pct)
      const now = Date.now()
      output.parts.push({
        id: makePartID(),
        messageID: output.message.id,
        sessionID: output.message.sessionID,
        type: "text",
        synthetic: true,
        text:
          `[Context pressure] This session is ~${u.pct.toFixed(0)}% through its context window. ` +
          "At the next boundary -- work committed, topic finished, nothing held only in memory -- " +
          "call the compact tool before starting anything large.",
        time: { start: now, end: now },
      } as never)
    },

    // A plain ToolDefinition shape; the registry only needs these three keys.
    tool: {
      compact: {
        description:
          "Compact this session's context. Older conversation is summarized into a compact summary and " +
          "recent turns are kept verbatim; tool outputs from pruned turns disappear from your context. " +
          "Use it proactively when the conversation is long and substantial work remains, or before " +
          "starting a large multi-step task near the end of a context window. Refuses while the context " +
          "is still mostly empty. After compacting you will be prompted to continue where you left off.",
        args: {},
        execute: async (_args: Record<string, never>, ctx: { sessionID: string }) => {
          const u = await usage(ctx.sessionID).catch(() => undefined)
          if (!u) return "Compaction is unavailable: no model has responded in this session yet."
          if (u.pct < MIN_PCT)
            return (
              `Refusing to compact: context usage is ~${u.pct.toFixed(0)}%, below the minimum of ` +
              `${MIN_PCT}%. Continue working; there is nothing worth summarizing yet.`
            )
          if (compactedAt.get(ctx.sessionID) === u.last.info.id)
            return "A compaction was already requested for this point in the conversation."

          await note("info", `queuing compaction for ${ctx.sessionID} at ${u.pct.toFixed(0)}%`)
          queueCompaction(ctx.sessionID, u.last.info)
          return (
            "Compaction queued. Finish your current step; right after it, older history is summarized " +
            "and you will be asked to continue on the compacted context."
          )
        },
      } satisfies {
        description: string
        args: Record<string, never>
        execute: (args: Record<string, never>, ctx: { sessionID: string }) => Promise<string>
      },
    },
  }
}
