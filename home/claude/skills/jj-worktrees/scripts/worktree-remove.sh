#!/usr/bin/env bash
# WorktreeRemove hook: forget the jj workspace, then delete its directory.
set -euo pipefail

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r .name)

jj workspace forget "$NAME" -R "${CLAUDE_PROJECT_DIR}" >&2
rm -rf "${CLAUDE_PROJECT_DIR}/.claude/worktrees/${NAME}"
