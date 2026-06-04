---
name: director
description: >
  Run a tmux/rmux director-workers orchestration: spawn and command multiple
  Claude Code workers in panes, each in its own git worktree, monitor their
  state with background watchers, and coordinate their output into PRs.
  Use when the user wants to parallelize work across multiple agent sessions,
  set up a multi-agent workflow on a server, or asks to "orchestrate" tasks
  across tmux panes.
---

# Director — tmux/rmux Multi-Worker Orchestration

> Full key/command cheat sheet: [rmux-reference.md](rmux-reference.md) · End-to-end flow: [WORKFLOW.md](../../WORKFLOW.md)

You are the **director**: a long-lived Claude Code session that commands N worker
Claude Code sessions running in tmux (or rmux) panes. Workers do the heavy
lifting; you plan, dispatch, monitor, integrate, and report.

## Topology

```
session "workers"           ← one tmux session, one window, N panes
  pane 0.0  → worker A (worktree wt-area-a)
  pane 0.1  → worker B (worktree wt-area-b)
  pane 0.2  → worker C (worktree wt-area-c)
session "director"          ← you live here
```

**One worker = one git worktree.** Workers sharing a checkout WILL destroy each
other's uncommitted state (a `git reset`/checkout by one wipes the others'
files). Create them before dispatching anything:

```bash
git worktree add .claude/worktrees/wt-area-a -b work/area-a origin/main
```

## Sending prompts to a worker (the protocol)

Every dispatch follows this exact sequence — each step exists because skipping
it caused a real failure:

```bash
rmux send-keys -t workers:0.N Escape   # 1. dismiss any overlay ("How is Claude doing?")
sleep 0.3
rmux send-keys -t workers:0.N C-u      # 2. clear the input line
sleep 0.3
rmux send-keys -t workers:0.N -l "the full prompt as ONE literal string"
sleep 0.5
rmux send-keys -t workers:0.N Enter    # 3. submit
```

Rules:
- **`-l` (literal) always** — without it, tmux interprets prompt text as key names.
- **NEVER blind-Enter a pane.** The input line often shows **ghost text** (dim
  autocomplete suggestions or a stale draft). It is NOT user input. Pressing
  Enter submits whatever is there. Clear with `C-u` first, always.
- Prompts must be **self-contained**: worktree path, branch-from ref, exact
  task, verification commands, and the standing rules (e.g. "NO merges — report
  back"). Workers have no access to your context.
- To **preserve a worker's context**, never restart its session — re-prompt it
  in place. A worker that built a plan keeps it; a restarted worker starts cold.

## Detecting worker state (WORKING vs IDLE)

Claude Code shows `esc to interrupt` while generating. In narrow panes (~60
cols) the bottom bar truncates, so grep for the **prefix only**:

```bash
busy=$(rmux capture-pane -p -t workers:0.N | grep -c 'esc to')
# busy>0 → WORKING ; busy=0 → idle candidate
```

**Debounce before declaring IDLE**: between tool calls the indicator blips off
for a few seconds. Require **6–8 consecutive idle polls at 20s intervals**
(~2 min) before treating a worker as done.

Pane titles are **stale** (they show the first prompt of the session) — never
use them for state.

## Watchers (the director's event loop)

Never poll in the foreground. Launch a background watcher per wave and let its
completion notification re-invoke you:

```bash
# run with run_in_background=true
declare -A ic; ic[0]=0; ic[1]=0
for i in $(seq 1 250); do
  for p in 0 1; do
    b=$(rmux capture-pane -p -t workers:0.$p | grep -c 'esc to')
    if [ "$b" -gt 0 ]; then ic[$p]=0; else ic[$p]=$((${ic[$p]}+1)); fi
    if [ "${ic[$p]}" -eq 8 ]; then
      echo "🔔 pane$p IDLE"
      rmux capture-pane -p -S -42 -t workers:0.$p | grep -vE '^\s*$' | tail -16
      exit 0
    fi
  done
  sleep 20
done; echo timeout
```

The `capture-pane -S -42 … | tail` dump gives you the worker's final report
without entering its pane. When the watcher fires, read the worker's output,
act (merge / re-dispatch / escalate), and arm the next watcher.

**A watcher can false-complete**: if a worker dies (rate limit, filter block),
it looks idle. On every IDLE signal, verify the expected artifact exists (the
report file, the PR, the branch) before treating the task as done — see the
`worker-recovery` skill for the failure taxonomy.

## Dispatch discipline

- **Partition by area, not by file**: workers in the same package/file collide.
  When two tasks must touch the same file (e.g. one CI workflow), give BOTH to
  the same worker as one cohesive task.
- **Mandate template**: context (1–2 lines) → worktree + branch command →
  numbered steps → verification commands → output contract ("write report to
  X" / "open PR, wait for bots, triage, do NOT merge") → escalation rule.
- **Queueing**: you may send a follow-up prompt while a worker is WORKING — it
  queues. Use it for addendums, not for new unrelated tasks.
- Workers report; the **director merges**. Never let workers merge to the
  integration branch — merge order is global knowledge only you have.

## Integration loop (per wave)

1. Watcher fires → read worker report (pane tail or report file).
2. Verify the artifact (PR exists, tests claimed green).
3. Run the PR triage flow (see `pr-triage` skill) and merge in dependency order.
4. Cut releases if applicable (see `release-train` skill).
5. Re-dispatch workers with the next wave; arm a new watcher.
6. Tell the user: what landed, what's in flight, what needs their decision.

## Anti-patterns (all caused real incidents)

| Anti-pattern | Consequence |
|---|---|
| Workers share one checkout | One worker's git surgery wiped another's uncommitted files |
| Blind Enter on a pane | Ghost text submitted as a prompt |
| `grep 'esc to interrupt'` in narrow panes | Truncated → permanent false IDLE |
| No debounce | Inter-tool blips → false IDLE → premature merge |
| Restarting a worker to "give it a new task" | Lost plan/context it had built |
| Director does worker-sized tasks inline | Context bloat; you lose the map |
| Trusting pane titles | They show the session's FIRST prompt forever |
