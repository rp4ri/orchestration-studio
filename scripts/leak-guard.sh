#!/bin/bash
# PreToolUse(Bash) guard: before an OUTWARD-facing git push / release upload,
# scan the outgoing commits for secrets and infra identifiers. Born from two
# real incidents while exporting a private codebase to a public repo:
#   1. TruffleHog --only-verified returned 0, but hardcoded infra IPs
#      (on the owner's explicit scrub list) sat in client source — secret
#      scanners don't classify identifiers as secrets.
#   2. The session's own first IP regex only matched `ip:port` forms, so the
#      BARE IPs slipped through the gate. A too-narrow pattern is worse than
#      none (false confidence).
#
# Heuristic and fast (pure git+grep, no external scanners): inspects only the
# ADDED lines of commits not yet on any remote. Warns (permissionDecision:
# "ask"), never hard-blocks — publishing already-shipped identifiers can be a
# deliberate call; the agent must make it consciously. Pair with a full
# TruffleHog pass for release exports (see the leak-guard notes in README).

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

case "$COMMAND" in
  *"git push"*|*"gh release upload"*|*"gh release create"*) : ;;
  *) exit 0 ;;
esac
# Tag deletions are cleanup, not publication.
case "$COMMAND" in
  *":refs/tags/"*) exit 0 ;;
esac

cd "$CWD" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Added lines of commits that exist on NO remote-tracking ref (what this push
# would publish). Cap the range so a huge history can't stall the hook.
OUTGOING=$(git log HEAD --not --remotes --max-count=200 --pretty=format: -p --unified=0 2>/dev/null \
  | grep '^+' | grep -v '^+++' | head -20000)
[ -z "$OUTGOING" ] && exit 0

FINDINGS=""

# Bare public IPv4 — match all dotted quads, then DROP private/loopback/link-local
# ranges (portable two-step instead of PCRE lookahead, which macOS grep lacks).
IPS=$(printf '%s' "$OUTGOING" \
  | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|0\.|255\.)' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.(0|255)$' \
  | sort -u | head -5)
[ -n "$IPS" ] && FINDINGS="$FINDINGS public-looking IPs: $(echo "$IPS" | tr '\n' ' ')."

# AWS instance ids and internal hostnames.
INFRA=$(printf '%s' "$OUTGOING" \
  | grep -oE 'i-[0-9a-f]{17}|[a-zA-Z0-9._-]+\.(internal|compute\.amazonaws\.com|rds\.amazonaws\.com)' \
  | sort -u | head -5)
[ -n "$INFRA" ] && FINDINGS="$FINDINGS infra identifiers: $(echo "$INFRA" | tr '\n' ' ')."

# Private key material / env files entering history.
KEYS=$(printf '%s' "$OUTGOING" | grep -cE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY')
[ "$KEYS" -gt 0 ] && FINDINGS="$FINDINGS $KEYS private-key block(s)."
ENVS=$(git log HEAD --not --remotes --max-count=200 --diff-filter=A --name-only --pretty=format: 2>/dev/null \
  | grep -E '(^|/)\.env$|\.pem$' | sort -u | head -5)
[ -n "$ENVS" ] && FINDINGS="$FINDINGS sensitive files added: $(echo "$ENVS" | tr '\n' ' ')."

if [ -n "$FINDINGS" ]; then
  jq -n --arg msg "leak-guard:$FINDINGS This push would publish them (public remotes are cached/indexed even after deletion). Verify each is intentional; for repo exports run TruffleHog + re-clone-and-grep the published result." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $msg
    }
  }'
fi
exit 0
