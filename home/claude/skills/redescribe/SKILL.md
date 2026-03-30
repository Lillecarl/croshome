---
name: redescribe
description: Improve commit messages on jj revisions when they're vague or unhelpful. Use when commit messages need better descriptions, or when the user asks to "redescribe" or "fix commit messages". Accepts an optional revset argument (e.g. `/redescribe vn..@`).
---

Analyze commits matching the given revset (or `mutable()` if none provided) and improve vague or unhelpful commit messages.

**Revset parameter**: The first argument is the revset to operate on. If omitted, defaults to `mutable()`.

1. Run `jj log -r '$revset' --no-pager --template builtin_log_detailed` to get all matching commits with their full messages. **Never use pipes** (|, head, tail, grep, cut, etc.) to select from command output — always get the full output and work with it directly.

2. A commit message is **OK** if it:
   - Describes *what* changed AND *why*
   - Is specific enough to understand without looking at the diff
   - Uses proper grammar and capitalization
   - Isn't placeholder text like "update", "fix", "changes", "wip"

3. For commits with **non-OK** messages, spawn subagents. At most five in parallel:
   - Pass to each subagent: the full `jj log` output (for adjacent commit context), the commit's revid, and the current commit message
   - **The subagent must never use pipes** (|, head, tail, grep, cut, sed, awk, etc.) to select from command output — always work with full output directly
   - Each subagent should:
     - Run `jj diff --git --revisions $jjrevid` to see the actual changes
     - Review adjacent commits for additional context
     - Think thoroughly about what the change does and why
     - Consider if the commit has **too many concerns** (should be split) or if it continues the previous commit's concern (should be squashed)
     - Generate an improved description following conventional commits style
     - Run `jj describe $jjrevid -m "$improved_message"` to apply the new description
     - Report whether the commit should be split, squashed, or is fine as-is

4. Report which commits were updated and their new messages. Include split/squash suggestions for the user's consideration.
