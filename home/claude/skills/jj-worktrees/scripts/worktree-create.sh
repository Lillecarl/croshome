#!/usr/bin/env bash
# WorktreeCreate hook: create a jj workspace instead of a git worktree.
set -euo pipefail

NAME=$(jq -r .name)
WORKTREES_DIR="${CLAUDE_PROJECT_DIR}/.claude/worktrees"
DIR="${WORKTREES_DIR}/${NAME}"
mkdir -p "$WORKTREES_DIR"

REVSET="${JJ_WORKTREES_BASE_REVSET:-trunk()}"

# trunk() falls back to root() (the empty commit) when no main/master/trunk
# bookmark exists -- true for most local-only jj repos with no remote. Forking
# from it would silently create an empty workspace, so detect that case and
# fall back to jj's own default: sibling of the current workspace's @.
if [ "$REVSET" = "trunk()" ] \
  && [ -z "$(jj log -r 'trunk() ~ root()' --no-graph -T 'commit_id' -R "${CLAUDE_PROJECT_DIR}" 2>/dev/null)" ]; then
  jj workspace add "$DIR" --name "$NAME" -R "${CLAUDE_PROJECT_DIR}" >&2
else
  jj workspace add "$DIR" --name "$NAME" -r "$REVSET" -R "${CLAUDE_PROJECT_DIR}" >&2
fi

echo "$DIR"
