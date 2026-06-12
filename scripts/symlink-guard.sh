#!/bin/bash
# PreToolUse(Bash) guard: before a `git commit`, reject staged SYMLINKS —
# especially anything named node_modules or pointing at an absolute path
# outside the repo. Born from a real incident: a worker's broad `git add` in
# its worktree committed two absolute-path `node_modules` symlinks (the
# repo's `.gitignore` had `node_modules/` — trailing slash = directories
# only, so the symlink FILES slipped through). macOS tolerated them; the
# release's Windows job died on `ENOTDIR: mkdir node_modules` → a partial,
# confusing release. The director's local platform passing is not evidence
# the build is clean.
#
# Also nudges on broad adds (`git add -A` / `git add .`) in worktrees, which
# is how the symlinks got staged in the first place.

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

case "$COMMAND" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

cd "$CWD" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Staged entries with mode 120000 = symlinks about to be committed.
SYMLINKS=$(git diff --cached --raw 2>/dev/null | awk '$2 == "120000" {print $NF}' | head -10)
[ -z "$SYMLINKS" ] && exit 0

BAD=""
for f in $SYMLINKS; do
  TARGET=$(git cat-file -p "$(git ls-files -s -- "$f" | awk '{print $2}')" 2>/dev/null)
  case "$f" in
    *node_modules*) BAD="$BAD $f -> $TARGET (node_modules symlink — breaks Windows CI: ENOTDIR on mkdir);" ; continue ;;
  esac
  case "$TARGET" in
    /*) BAD="$BAD $f -> $TARGET (absolute-path target — meaningless on any other machine);" ;;
  esac
done
[ -z "$BAD" ] && exit 0

jq -n --arg msg "symlink-guard: staged symlinks about to be committed:$BAD Unstage them (git rm --cached <path>) and commit only the files you changed — never 'git add -A' in a worktree. Note: gitignore 'node_modules/' (trailing slash) does NOT match symlink files; use 'node_modules'. macOS tolerates what Windows CI fails on." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $msg
  }
}'
exit 0
