---
name: pr-triage
description: >
  Triage automated bot reviews (Gemini Code Assist, Codex, etc.) on GitHub PRs
  before merging: wait out the review cycle, count unanswered bot observations,
  fix the legitimate ones with commits, justify rejections in-thread, and gate
  merges on zero unanswered comments. Use when handling PR reviews, deciding
  whether a PR is ready to merge, or coordinating merges across many PRs.
---

# PR Triage — Bot Review Discipline

The rule that keeps a high-velocity multi-agent repo clean: **a PR merges only
when every bot observation has been answered** — either fixed with a commit, or
rejected with a reasoned reply in the same thread. Silence is not an answer.

## The cycle

1. **Open the PR**, then wait one bot cycle (~5–6 minutes). Run the wait in the
   background so it doesn't block you:

```bash
sleep 330
gh pr view <N> -R <owner/repo> --json reviews,mergeable,mergeStateStatus \
  -q '"reviews="+(.reviews|length|tostring)+" ["+(.mergeable)+"/"+(.mergeStateStatus)+"]"'
```

2. **Count unanswered bot comments** — the core query. A bot comment is
   "unanswered" if it's a top-level inline comment by a bot with no reply from
   the maintainer account in its thread:

```bash
gh api "repos/<owner/repo>/pulls/<N>/comments?per_page=100" --jq '
  [.[] | select(.user.login=="<your-login>") | .in_reply_to_id] as $replied |
  [.[] | select((.user.login|test("bot$|gemini|codex";"i")) and (.in_reply_to_id==null))]
  | map(select(.id as $i | ($replied|index($i))|not)) | length'
```

3. **Triage each observation**:
   - **Legit** → fix it in a new commit, then reply in-thread referencing the
     SHA: `Legit (P2): fixed in <sha> — <one-line summary of the change>`.
   - **Not legit** → reply with the concrete reason (constraint it missed,
     intended behavior, out of scope) — never just "wontfix".
   - Reply via: `gh api repos/<o/r>/pulls/<N>/comments/<comment-id>/replies -f body="..."`

4. **Gate the merge**: unanswered == 0 AND `mergeable=MERGEABLE/CLEAN` → merge.
   Anything else → keep triaging or rebase.

   **`unanswered=0` is ambiguous — it also reads "bots haven't commented
   YET".** A merge-readiness watcher that exits on the first all-zero poll
   races the bot cycle (real incident: a watcher declared 3 PRs clean 90s
   after opening; the bot's comment landed minutes later). Make zero mean
   *triaged*, not *early*:
   - require `reviews > 0` for the PR (or the full wait window elapsed — the
     CI-only-PR exception below), AND
   - require **two consecutive all-zero polls** (minutes apart) before
     declaring triage complete.

## Severity heuristics

Bots tag severity (P1/P2, critical/high/medium). Calibration from production:
- **P1/critical**: treat as blocking, verify the claim yourself before fixing —
  but bots are often RIGHT about crash-paths (unhandled rejections, non-idempotent
  migrations, TTY-less CI behavior). These caught real outages-in-waiting.
- **P2/medium**: usually legit small improvements; fix if cheap, justify if not.
- Bots reviewing **workflow/CI files often skip entirely** (0 reviews ≠ broken
  pipeline; after the wait window, 0 reviews = proceed).

## Merge ordering across many PRs

- Re-check `mergeable` for ALL open PRs after every merge — merges flip others
  to CONFLICTING. Rebase those before continuing.
- Merge order = dependency order, not PR number. Disjoint-file PRs can merge
  back-to-back; same-file PRs must be serialized (or consolidated into one
  branch by a single worker).
- A PR superseded by another (its changes absorbed) gets **closed with a
  comment** pointing to the superseding PR — not merged.

## Delegating triage to workers

When the PR's author-worker is alive, triage is **its** responsibility — send
it: "Bots left N observations on #X — triage them (fix legit with commits /
justify rejections in-thread). Report when unanswered=0. Do NOT merge."
The director only verifies the count went to zero and merges.
