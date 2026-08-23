// Lets an agent compact its own context with a tool call.
//
// How opencode models compaction internally: a compaction is a user message
// carrying a `compaction` part. The run loop re-reads the message list at the
// top of every iteration and processes such parts as queued tasks. After the
// summary is written, opencode injects a synthetic "Continue if you have next
// steps" user message, so the same run picks the work back up on the compacted
// context.
//
// The HTTP endpoint POST /session/:id/summarize does exactly "queue compaction,
// then run". Awaiting it from inside a tool would deadlock: the server sees
// the session busy and waits for the current run, which waits for this tool.
// Fired without awaiting, the part lands in storage while the model finishes
// its current step, and the running loop processes it as the next task. If the
// run has already ended, the endpoint simply starts a fresh run instead. Both
// orderings converge on the same result.
//
// This file must not use runtime bare-specifier imports ("@opencode-ai/plugin").
// Plugin discovery follows the symlink to this repo, where no node_modules
// chain exists, so a runtime import fails to resolve and the plugin silently
// never loads. Type-only imports are fine: they disappear at transpile.
import type { Plugin } from "@opencode-ai/plugin"

export const SelfCompact: Plugin = async ({ client }) => {
  const requested = new Set<string>()
  // Set OPENCODE_SELF_COMPACT_DEBUG=1 to log each queue request.
  const debug = !!process.env.OPENCODE_SELF_COMPACT_DEBUG

  const note = async (level: "debug" | "info" | "warn" | "error", message: string) => {
    if (level === "debug" && !debug) return
    await client.app.log({ body: { service: "self-compact", level, message } }).catch(() => {})
  }

  const hooks = {
    event: async ({ event }: { event: { type: string; properties: any } }) => {
      if (event.type === "session.deleted") requested.delete(event.properties.info.id)
    },

    // A plain ToolDefinition shape; the registry only needs these three keys.
    tool: {
      compact: {
        description:
          "Compact this session's context. Older conversation is summarized into a compact summary and " +
          "recent turns are kept verbatim; tool outputs from pruned turns disappear from your context. " +
          "Use it proactively when the conversation is long and substantial work remains, or before " +
          "starting a large multi-step task near the end of a context window. After compacting you will " +
          "be prompted to continue where you left off.",
        args: {},
        execute: async (_args: Record<string, never>, ctx: { sessionID: string }) => {
          if (requested.has(ctx.sessionID)) return "Compaction was already requested for this session."
          requested.add(ctx.sessionID)

          const messages = (await client.session.messages({ path: { id: ctx.sessionID } })).data ?? []
          const lastAssistant = [...messages].reverse().find((m) => m.info.role === "assistant")
          const providerID = lastAssistant?.info.providerID
          const modelID = lastAssistant?.info.modelID
          if (!providerID || !modelID) {
            requested.delete(ctx.sessionID)
            return "Compaction is unavailable: no model has responded in this session yet."
          }

          await note("info", `queuing compaction for ${ctx.sessionID} (${providerID}/${modelID})`)
          // Fire-and-forget on purpose; see the header comment for why.
          client.session.summarize({
            path: { id: ctx.sessionID },
            body: { providerID, modelID, auto: true },
          }).catch((e: unknown) => note("error", `summarize failed for ${ctx.sessionID}: ${e}`))

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
  return hooks
}
