// Forces continuation when a turn ends without doing anything.
//
// Two failure shapes reach the idle state, and opencode treats both as done:
//
// 1. A provider error that survives (or never enters) opencode's internal
//    retry policy -- five attempts, pattern-matched only. The assistant
//    message then carries an `error` object.
// 2. An empty response: the provider returns a clean finish with no content
//    at all. Seen live on openrouter -- a message whose only parts were
//    step-start/step-finish, zero tokens, zero cost, `finish: "stop"`. No
//    error object is set, so error-only detection misses it.
//
// This plugin watches session.idle for both shapes and sends a continuation
// prompt back into the same session.
import type { Plugin } from "@opencode-ai/plugin"

const MAX_ATTEMPTS = 3
const BASE_DELAY_MS = 2000

// Never continue past these. Fixing them needs a person or compaction, so a
// retry would only burn tokens against a wall.
const FATAL = new Set(["ProviderAuthError", "MessageAbortedError", "ContextOverflowError"])

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export const RetryStop: Plugin = async ({ client }) => {
  const attempts = new Map<string, number>()
  // Set OPENCODE_RETRY_STOP_DEBUG=1 to log every idle evaluation.
  const debug = !!process.env.OPENCODE_RETRY_STOP_DEBUG

  return {
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        attempts.delete(event.properties.info.id)
        return
      }
      if (event.type !== "session.idle") return
      const sessionID = event.properties.sessionID
      if (debug)
        await client.app.log({
          body: { service: "retry-stop", level: "debug", message: `evaluating idle ${sessionID}` },
        })

      try {
        // The idle event fires while the run loop is still tearing down.
        // Wait it out, then confirm nothing else has taken over the session.
        await sleep(1000)
        const status = (await client.session.status()).data?.[sessionID]
        if (status && status.type !== "idle") return

        // Subagent sessions are owned by their parent's task machinery;
        // prompting into one from outside would corrupt that state.
        const session = (await client.session.get({ path: { id: sessionID } })).data
        if (!session || session.parentID) return

        const messages = (await client.session.messages({ path: { id: sessionID } })).data ?? []
        const lastAssistant = [...messages].reverse().find((m) => m.info.role === "assistant")
        if (!lastAssistant) return

        const error = lastAssistant.info.error
        // An empty turn: no part beyond the step markers the loop itself
        // writes. This is what a provider "just stopping" looks like.
        const isEmptyTurn =
          !error &&
          lastAssistant.parts.length > 0 &&
          !lastAssistant.parts.some((p) => (p.type as string) !== "step-start" && (p.type as string) !== "step-finish")
        if (!error && !isEmptyTurn) {
          attempts.delete(sessionID) // clean turn; reset the counter
          return
        }
        // Anything newer than the failure means someone intervened.
        if (messages[messages.length - 1].info.id !== lastAssistant.info.id) return

        if (error && FATAL.has(error.name)) return

        const reason = error ? error.name : "empty response"
        const attempt = attempts.get(sessionID) ?? 0
        if (attempt >= MAX_ATTEMPTS) {
          await client.app.log({
            body: {
              service: "retry-stop",
              level: "warn",
              message: `giving up on ${sessionID} after ${attempt} continuations (${reason})`,
            },
          })
          return
        }
        attempts.set(sessionID, attempt + 1)

        await sleep(BASE_DELAY_MS * 2 ** attempt)
        const detail =
          typeof error?.data === "object" && error.data && "message" in error.data
            ? String((error.data as { message: unknown }).message)
            : reason
        await client.app.log({
          body: {
            service: "retry-stop",
            level: "info",
            message: `continuing ${sessionID} after ${reason}: ${detail} (attempt ${attempt + 1}/${MAX_ATTEMPTS})`,
          },
        })
        await client.session.prompt({
          path: { id: sessionID },
          body: {
            parts: [
              {
                type: "text",
                text: `The previous turn ended without producing anything (${detail}). Continue where you left off.`,
              },
            ],
          },
        })
      } catch (e) {
        await client.app.log({
          body: { service: "retry-stop", level: "error", message: `${e}` },
        })
      }
    },
  }
}
