// Enforces an explicit end-of-turn contract: the model must call the
// `needs_user` tool before it may stop. Nothing else ends a turn.
//
// The point is to stop the model stopping when it should not. A model that
// knows the next step still likes to write a summary, hand the turn back and
// wait. That stop costs a full round trip and buys nothing. So the gate
// treats a summary as work in progress, not as an ending: the model keeps
// going, and says what it did on the way past. Only two things end a turn --
// the work is done, or a decision only the user can make blocks it.
//
// Why: detecting *why* a turn died is a catalogue of failure modes -- empty
// response, dropped stream, half-written reply. Under provider load a model
// "just stops" in a hundred ways, and guessing at each one is brittle. One
// explicit contract replaces them all: to stop, call needs_user. If the
// model stops without it, this plugin nudges it once (per the backoff
// ladder) to keep working or close out properly.
//
// Enabled by OPENCODE_NEEDS_USER=1 so it can be switched on per session.
// While enabled, retry-stop disables itself: the gate subsumes its empty
// and error heuristics, and both firing would double the nudges.
//
// The instruction reaches the model two ways:
//   - the tool's own description, offered on every turn (registry tools are
//     auto-injected, exactly like the compact tool);
//   - a synthetic reminder appended to each user message via chat.message,
//     the same proven mechanism self-compact's context hints use.
//
// `experimental.chat.system.transform` would be the natural home for the
// standing instruction, but it is declared in the plugin types yet not wired
// into this opencode build's prompt assembly, so chat.message is used.
import type { Plugin } from "@opencode-ai/plugin"

const ENABLED = process.env.OPENCODE_NEEDS_USER === "1"

const BASE_DELAY_MS = Number(process.env.OPENCODE_NEEDS_USER_BASE_DELAY_MS) || 2000
const MAX_DELAY_MS = Number(process.env.OPENCODE_NEEDS_USER_MAX_DELAY_MS) || 60000
const WINDOW_MS = Number(process.env.OPENCODE_NEEDS_USER_WINDOW_MS) || 3_600_000

// One nudge phrasing is enough: the contract is singular, so a rotating pool
// would only blur it. The template is machine-flavored enough to match by.
const NUDGE = (detail: string) =>
  `You ended your turn without calling needs_user (${detail}). Two things end a turn: the work is done, or a decision only the user can make blocks you. A summary is neither. If you know the next step, take it now. If you are actually finished, call needs_user.`
const NUDGE_PATTERN = /^You ended your turn without calling needs_user \(.+\)\. /

const REMINDER =
  "End-of-turn contract: before you stop responding, you MUST call the needs_user tool. " +
  "Two things earn that call: the work is done, or a decision only the user can make blocks you. " +
  "Do not stop to write a summary, to report progress, or to ask whether to continue. " +
  "If you know the next step, take it in this turn and report it on the way past."

// Fatal errors still must not be pushed through. Fixing them needs a person.
const FATAL = new Set(["ProviderAuthError", "MessageAbortedError", "ContextOverflowError"])

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

type AnyMessage = { info: { id: string; role: string; finish?: string; error?: unknown; mode?: string }; parts: Array<{ type: string; tool?: string; text?: string }> }

const isCompactionMsg = (m: AnyMessage) => m.info.role === "assistant" && (m.info.mode === "compaction" || m.info.finish === "error")

const isNudge = (m: AnyMessage) =>
  m.info.role === "user" &&
  m.parts.length === 1 &&
  m.parts[0].type === "text" &&
  !!m.parts[0].text &&
  NUDGE_PATTERN.test(m.parts[0].text)

export const NeedsUser: Plugin = async ({ client }) => {
  // One entry per failure streak: nudges sent, and when the streak began.
  const episodes = new Map<string, { attempt: number; since: number }>()
  const debug = !!process.env.OPENCODE_NEEDS_USER_DEBUG

  const note = async (level: "debug" | "info" | "warn" | "error", message: string) => {
    if (level === "debug" && !debug) return
    await client.app.log({ body: { service: "needs-user", level, message } }).catch(() => {})
  }

  // The model's last assistant message that actually called a tool. Called
  // needs_user means the turn closed out deliberately.
  const lastToolCall = (messages: AnyMessage[]) =>
    [...messages].reverse().find((m) => m.info.role === "assistant" && m.parts.some((p) => p.type === "tool"))

  const sweepNudges = async (sessionID: string, messages: AnyMessage[]) => {
    for (const m of messages) {
      if (!isNudge(m)) continue
      try {
        await client.session.deleteMessage({ sessionID, messageID: m.info.id })
      } catch {
        // A busy session or a gone message must never break the gate.
      }
    }
  }

  return {
    event: async ({ event }) => {
      if (!ENABLED) return
      if (event.type === "session.deleted") {
        episodes.delete(event.properties.info.id)
        return
      }
      if (event.type !== "session.idle") return
      const sessionID = event.properties.sessionID

      try {
        // The idle event fires during run-loop teardown; wait it out.
        await sleep(1000)
        const status = (await client.session.status()).data?.[sessionID]
        if (status && status.type !== "idle") return

        // Subagent sessions are owned by their parent's task machinery.
        const session = (await client.session.get({ path: { id: sessionID } })).data
        if (!session || session.parentID) return

        const messages = (await client.session.messages({ path: { id: sessionID } })).data ?? []
        const lastUserIndex = messages.map((m) => m.info.role === "user").lastIndexOf(true)
        const turn = lastUserIndex === -1 ? messages : messages.slice(lastUserIndex + 1)
        const lastAssistant = [...turn].reverse().find((m) => m.info.role === "assistant" && m.info.finish && !isCompactionMsg(m))
        if (!lastAssistant) return

        // The turn called needs_user: it ended the way the contract demands.
        const toolMsg = lastToolCall(turn)
        if (toolMsg?.parts.some((p) => p.type === "tool" && p.tool === "needs_user")) {
          episodes.delete(sessionID)
          await sweepNudges(sessionID, messages)
          return
        }

        const error = lastAssistant.info.error
        if (error && FATAL.has((error as { name?: string }).name ?? "")) return

        // Anything newer than the failure means someone intervened.
        if (messages[messages.length - 1].info.id !== lastAssistant.info.id) return

        const reason = error ? (error as { name?: string }).name ?? "error" : "no needs_user call"
        const now = Date.now()
        const ep = episodes.get(sessionID) ?? { attempt: 0, since: now }
        if (now - ep.since >= WINDOW_MS) {
          episodes.delete(sessionID)
          await note("warn", `giving up on ${sessionID} after ${Math.round((now - ep.since) / 60000)} minutes (${reason})`)
          return
        }
        ep.attempt += 1
        episodes.set(sessionID, ep)

        await sweepNudges(sessionID, messages)

        const delay = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** (ep.attempt - 1))
        await sleep(delay)
        await note("info", `continuing ${sessionID}: ${reason} (continuation ${ep.attempt})`)
        await client.session.prompt({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: NUDGE(reason) }],
          },
        })
      } catch (e) {
        await note("error", `${e}`)
      }
    },

    // Standing reminder, riding each user message so the model sees it every
    // turn. The synthetic part persists, the same way context hints do.
    "chat.message": async (_input, output) => {
      if (!ENABLED) return
      output.parts.push({
        id: `prt_${Math.random().toString(36).slice(2)}`,
        messageID: output.message.id,
        sessionID: output.message.sessionID,
        type: "text",
        synthetic: true,
        text: REMINDER,
        time: { start: Date.now(), end: Date.now() },
      } as never)
    },

    tool: {
      needs_user: {
        description:
          "Call this when a decision only the user can make blocks you, or when the work is complete and you are about to end your turn. " +
          "You MUST call this before ending a turn; ending without it is treated as a failure. " +
          "Do not call it to deliver a summary, to report progress, or to ask whether to continue -- if you know the next step, take it instead.",
        args: {},
        execute: async (_args: Record<string, never>) => {
          return "User notified. You may end your turn."
        },
      } satisfies {
        description: string
        args: Record<string, never>
        execute: (args: Record<string, never>) => Promise<string>
      },
    },
  }
}
