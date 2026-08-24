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
//
// Policy: exponential backoff from 2s capped at 60s, rotating through a
// small pool of phrasings so the same sentence does not become wallpaper.
// One failure streak may be pushed for up to an hour, then the plugin logs
// a warning and leaves the session alone. A clean turn ends the streak;
// auth errors, aborts and context overflow stay fatal. Knobs:
// OPENCODE_RETRY_STOP_BASE_DELAY_MS, OPENCODE_RETRY_STOP_MAX_DELAY_MS and
// OPENCODE_RETRY_STOP_WINDOW_MS override those defaults.
import type { Plugin } from "@opencode-ai/plugin"

const BASE_DELAY_MS = Number(process.env.OPENCODE_RETRY_STOP_BASE_DELAY_MS) || 2000
const MAX_DELAY_MS = Number(process.env.OPENCODE_RETRY_STOP_MAX_DELAY_MS) || 60000
const WINDOW_MS = Number(process.env.OPENCODE_RETRY_STOP_WINDOW_MS) || 3_600_000

// Rotation keeps repeated nudges from reading as one stuck record. Every
// variant carries the failure detail and asks for the same thing: resume.
const PROMPTS = [
  (detail: string) => `The previous turn ended without producing anything (${detail}). Continue where you left off.`,
  (detail: string) => `Nothing came back from the provider (${detail}). Pick up exactly where you stopped.`,
  (detail: string) => `That turn was lost (${detail}). Resume the task from your last completed step.`,
  (detail: string) => `Your last reply never arrived (${detail}). Continue working on the current task.`,
]

// Never continue past these. Fixing them needs a person or compaction, so a
// retry would only burn tokens against a wall.
const FATAL = new Set(["ProviderAuthError", "MessageAbortedError", "ContextOverflowError"])

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export const RetryStop: Plugin = async ({ client }) => {
  // One entry per failure streak: how many nudges went out, and when the
  // streak started. The clock, not a count, decides when to give up.
  const episodes = new Map<string, { attempt: number; since: number }>()
  // Set OPENCODE_RETRY_STOP_DEBUG=1 to log every idle evaluation.
  const debug = !!process.env.OPENCODE_RETRY_STOP_DEBUG

  return {
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        episodes.delete(event.properties.info.id)
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
          episodes.delete(sessionID) // clean turn; end the streak
          return
        }
        // Anything newer than the failure means someone intervened.
        if (messages[messages.length - 1].info.id !== lastAssistant.info.id) return

        if (error && FATAL.has(error.name)) return

        const reason = error ? error.name : "empty response"
        const now = Date.now()
        const ep = episodes.get(sessionID) ?? { attempt: 0, since: now }
        if (now - ep.since >= WINDOW_MS) {
          episodes.delete(sessionID)
          await client.app.log({
            body: {
              service: "retry-stop",
              level: "warn",
              message: `giving up on ${sessionID} after ${Math.round((now - ep.since) / 60000)} minutes of continuations (${reason})`,
            },
          })
          return
        }
        ep.attempt += 1
        episodes.set(sessionID, ep)

        const delay = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** (ep.attempt - 1))
        await sleep(delay)
        const detail =
          typeof error?.data === "object" && error.data && "message" in error.data
            ? String((error.data as { message: unknown }).message)
            : reason
        await client.app.log({
          body: {
            service: "retry-stop",
            level: "info",
            message: `continuing ${sessionID} after ${reason}: ${detail} (continuation ${ep.attempt}, waited ${delay / 1000}s)`,
          },
        })
        await client.session.prompt({
          path: { id: sessionID },
          body: {
            parts: [
              {
                type: "text",
                text: PROMPTS[(ep.attempt - 1) % PROMPTS.length](detail),
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
