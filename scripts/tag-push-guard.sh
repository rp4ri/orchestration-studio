#!/bin/bash
# PreToolUse(Bash) guard: when a `git push` includes a tag name, verify the
# local tag's commit matches the current remote tip of the branch it's meant
# to release. Born from a real incident: a failed `git tag -d` left a STALE
# local tag, the re-create silently failed ("already exists"), and the push
# shipped a tag pointing at an old commit — CI built a release WITHOUT the fix.
#
# Heuristic, deliberately conservative: only inspects `git push ... <tag>`
# where <tag> resolves to a local tag. Warns (does not block) when the tag's
# commit is not contained in any remote-tracking head — enough signal for the
# agent to stop and re-check before publishing.

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

case "$COMMAND" in
  *"git push"*) : ;;
  *) exit 0 ;;
esac

# Skip tag deletions (":refs/tags/...") — those are intentional cleanup.
case "$COMMAND" in
  *":refs/tags/"*) exit 0 ;;
esac

cd "$CWD" 2>/dev/null || exit 0

WARNINGS=""
for word in $COMMAND; do
  # Candidate tag tokens: not flags, not remotes, resolvable as a local tag.
  case "$word" in
    git|push|-*|origin|upstream) continue ;;
  esac
  if git rev-parse -q --verify "refs/tags/$word" >/dev/null 2>&1; then
    TAG_COMMIT=$(git rev-parse "$word^{commit}" 2>/dev/null)
    # Is the tag's commit an ancestor of (or equal to) ANY remote-tracking head?
    CONTAINED=$(git branch -r --contains "$TAG_COMMIT" 2>/dev/null | head -1)
    if [ -z "$CONTAINED" ]; then
      WARNINGS="$WARNINGS Tag '$word' -> ${TAG_COMMIT:0:8} is not contained in any remote-tracking branch (stale tag? unpushed base?)."
    fi
  fi
done

if [ -n "$WARNINGS" ]; then
  jq -n --arg msg "tag-push-guard:$WARNINGS Verify with: git rev-parse <tag>^{commit} vs git rev-parse origin/<branch> before pushing." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $msg
    }
  }'
  exit 0
fi

exit 0
