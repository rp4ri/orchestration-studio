---
name: consolidate
description: >
  Merge N CLEAN PRs through one integration branch: combine them on an aux
  branch, verify the COMBINED build/typecheck, open a single PR to main, and
  sweep the issues that "Closes #N" did not auto-close. Use when a wave
  produced several ready PRs at once, when sequential direct-to-main merges
  risk semantic conflicts, or when consolidating before a release.
---

# Consolidate — N CLEAN PRs via One Integration Branch

Each PR in a wave is individually green, but the **combined** result can fail
to typecheck or build (semantic conflicts: one PR renames what another calls).
Merging one-by-one to main pollutes it with intermediate states and only
discovers the breakage at the end. Run the combination on an aux branch and
gate on the combined state — used in production for batches of 4, 7 and 7 PRs,
zero conflicts (worktree-per-worker + area-partitioned dispatch is what makes
that the normal outcome).

## The sequence

```bash
git fetch origin -q
git checkout -B integration/consolidate-r1 origin/main
for b in <pr-branch-1> <pr-branch-2> <pr-branch-3>; do
  git merge --no-edit "origin/$b" || { git merge --abort; echo "CONFLICT: $b — leaving it out"; }
done
# verify the COMBINED state (cheap local gate, full build belongs to CI):
<scoped typecheck/tests, e.g. pnpm --filter server exec tsc --noEmit>
git push -u origin integration/consolidate-r1
gh pr create --base main --head integration/consolidate-r1 --title "integration: consolidate r1 (#A #B #C)"
```

Rules:

- **Conflict → report, exclude, continue.** A conflicting PR drops out of the
  batch with a note naming it; it gets rebased separately. Never hand-resolve
  inside the integration branch — the conflict belongs to the PR's owner.
- **CI on the integration PR is the real gate** — it validates the combined
  state no individual PR ever saw.
- Merge the ONE integration PR; main receives a single clean consolidation.
- **After merging, re-check every remaining open PR** — the consolidation can
  flip them to CONFLICTING (same rule as serial merges).

## The `Closes #N` gotcha (cost real manual cleanup)

**GitHub only processes closing keywords from the body of the PR that merges
into the default branch.** `Closes #N` in the individual PRs' bodies does NOT
fire when their commits land via the integration branch — ~6 issues once
stayed open despite being fixed and merged. Handle it explicitly:

- Collect every `Closes #N` from the batched PRs into the **integration PR's
  body**, or
- Run a **post-merge sweep**: for each batched PR, close its referenced issues
  with a comment citing the integration PR.

```bash
# harvest the closing refs from the batched PRs:
for n in <pr-numbers>; do
  gh pr view $n --json body -q .body | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+'
done
```

## When NOT to consolidate

- Two PRs in the batch touch the same files in conflicting ways — serialize
  those through their owners instead.
- A PR needs an independent revert lever (risky change you may want to back
  out alone) — merge it separately; consolidation couples its history to the
  batch.
