# Agent Guidelines

## Version Control

This repo uses **jj (Jujutsu)** as its VCS. Always use jj commands instead of git.

- Load the **jj** skill before performing any version control operations
- Load the **jj-hunk** skill for partial commits, splits, or selective squashing
- Use `jj --no-pager` for all jj commands to avoid pager issues
- Prefer `jj commit -m "msg"` over `jj describe` when finishing a task
- Never use `git` directly — use jj equivalents instead