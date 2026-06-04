# The Agent Workflow — End to End

The canonical flow a director session follows with its workers, from dispatch
to merged release. Every skill in this repo is a zoom-in on one box.

```
0. SETUP      one tmux/rmux session, N panes, one git WORKTREE per worker
1. DISPATCH   director → worker: send-keys with a self-contained mandate
2. WORK       worker implements in ITS worktree, verifies, opens a PR
3. BOT WAIT   ~5–6 min background wait for Code Assistant reviews
4. TRIAGE     every bot observation answered: fix+SHA reply, or justified reject
5. VERIFY     director: unanswered==0, MERGEABLE/CLEAN, artifacts exist
6. MERGE      the DIRECTOR merges (never the worker), in dependency order
7. RELEASE    tag-driven, verify tag→tip before push, background run-watcher
8. MONITOR    watchers fire → read reports → dispatch the next wave
```

---

## 0. Setup — worktree-per-worker isolation

**Why**: workers sharing one checkout WILL destroy each other — a
`git checkout`/`reset` by worker B silently wipes worker A's uncommitted
files (real incident; A survived only because it had committed minutes
earlier).

**How** (director, once per worker, from the main repo):

```bash
git worktree add .claude/worktrees/wt-area-a -b work/area-a origin/main
git worktree add .claude/worktrees/wt-area-b -b work/area-b origin/main
git worktree add .claude/worktrees/wt-area-c -b work/area-c origin/main
```

Rules that make the isolation actually hold:

1. **Every mandate names the worktree path explicitly** — and the worker must
   use the WORKTREE path in every file operation (Edit/Read/Write). Touching
   the main-repo path from a worker bypasses the isolation entirely.
2. Workers create **per-task branches inside their worktree**:
   `git fetch && git switch -c fix/thing origin/main`. Worktree = workspace;
   branch = task.
3. **Partition tasks by area** so no two workers touch the same files. Two
   tasks on the SAME file (e.g. one CI workflow) go to the SAME worker as one
   cohesive mandate.
4. Mid-session re-isolation: prompt the worker to create/switch worktrees
   ITSELF — never restart its session (you'd lose its accumulated context).
5. Retire an area with `git worktree remove .claude/worktrees/wt-x`.

## 1. Dispatch (director → worker)

Exact keys in [skills/director/rmux-reference.md](skills/director/rmux-reference.md).
Mandates are **self-contained** — workers share zero context with the director:

- Context: 1–3 lines (what's confirmed, PR references).
- Workspace: `En <worktree-path> → git fetch && git switch -c <branch> origin/main`.
- Numbered steps.
- Verification commands (typecheck/build/tests the worker must run).
- Output contract: "open PR → wait for bots → triage → do **NOT** merge —
  report back" (or "write report to <path>" for audits).
- Escalation rule ("if X happens, stop and report").

## 2. Work

The worker implements, self-verifies, pushes its branch, opens the PR
(`gh pr create`), and waits for the bot cycle — usually with its own timer.

## 3. Bot wait — how we wait for Code Assistant observations

Reviews from Gemini Code Assist / Codex land **2–6 minutes** after the PR
opens. The wait runs in the **background** (never block the director):

```bash
# run_in_background=true — the completion notification re-invokes you
sleep 330
gh api "repos/$REPO/pulls/$N/comments?per_page=100" --jq '
  [.[] | select(.user.login=="<maintainer>") | .in_reply_to_id] as $replied |
  [.[] | select((.user.login|test("bot$|gemini|codex";"i")) and (.in_reply_to_id==null))]
  | map(select(.id as $i | ($replied|index($i))|not)) | length'
gh pr view $N --json reviews,mergeable,mergeStateStatus
```

Calibration:
- Bots sometimes arrive **late** (after the first window) — re-check before
  merging, not just once after opening.
- Bots often **skip CI/workflow-only PRs** entirely: after the wait window,
  `reviews=0` on those means proceed, not broken.
- Severity badges (P1/P2, critical/high/medium) come embedded in the comment
  body — P1s have caught real outages-in-waiting; verify, then fix.

## 4. Triage

Owner of the PR (worker for its PRs, director for its own) answers EVERY
observation **in-thread**:

- **Legit** → fix in a new commit, reply: `Legit (P2): fixed in <sha> — <what changed>`.
- **Reject** → reply with the concrete reason. Silence is not an answer.

```bash
gh api repos/$REPO/pulls/$N/comments/<comment-id>/replies -f body="..."
```

## 5–6. Verify, then merge (director only)

```bash
# gate: unanswered==0 AND clean
gh pr view $N --json mergeable,mergeStateStatus
gh pr merge $N --merge
# after EVERY merge: re-check remaining PRs — merges flip them to CONFLICTING
```

Workers never merge: merge order is global knowledge (dependencies, releases,
who else is mid-rebase) that only the director holds.

## 7. Release

See `skills/release-train`. Non-negotiables: annotated tag on the verified
tip (`git rev-parse <tag>^{commit}` == intended tip **before** pushing),
background `gh run watch --exit-status`, post-release verification baked into
the watcher (assets exist, health endpoint 200, updater manifests intact).

## 8. Monitor → next wave

Background watchers over panes (`grep -c 'esc to'`, debounced ≥6–8 polls)
fire when workers go idle → director reads the pane tail / report file →
**verifies the artifact exists** (idle + missing artifact = incident, see
`skills/worker-recovery`) → triages/merges → dispatches the next wave →
arms the next watcher → reports to the user.
