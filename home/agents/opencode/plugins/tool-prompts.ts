import type { Plugin } from "@opencode-ai/plugin"

// Rewrites what the built-in read, edit and write tools say about
// themselves. Both changes are about pyedit:
//
// - The read-first compliance bullets ("must Read at least once before
//   editing", "will fail if you did not read") push every change through
//   edit, however many places it touches, and pyedit is the stronger tool
//   for exactly those. They go from the descriptions. What the tools
//   enforce at run time is untouched.
// - No built-in description mentions pyedit. The edit tool gains a line
//   that hands a scripted edit -- several files at once, or one file in
//   many places -- over to it.
//
// The hook runs per tool per session on a fresh copy of the built-in
// description each time, so nothing accumulates; the guard is insurance
// against a future opencode that reuses one copy.

// A line that matches one of these is read-before-edit compliance, and
// comes out of the description.
const compliance = [
  /read.*tool.*at least once.*before editing/i,
  /without reading the file/i,
  /must use the read tool first/i,
  /fail if you did not read/i,
]

const pyedit =
  "\n\nFor a scripted edit -- several files at once, or one file in many " +
  "places -- `pyedit` is the stronger tool: it stages edits in memory, " +
  "shows them as dry-run diffs, and writes to disk only on `--apply`. " +
  "Run `pyedit skill` for its full instructions."

export const ToolPrompts: Plugin = async () => ({
  "tool.definition": async (input, output) => {
    if (input.toolID !== "edit" && input.toolID !== "write") return
    const lines = output.description.split("\n").filter(
      (line) => !compliance.some((one) => one.test(line)),
    )
    const grown = input.toolID === "edit" && !output.description.includes("pyedit")
    output.description = lines.join("\n") + (grown ? pyedit : "")
  },
})
