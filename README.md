# Orchestration Studio

Multi-agent orchestration toolkit for [Claude Code](https://code.claude.com) —
distilled from real production sessions running a **director** Claude Code
instance commanding multiple **worker** instances over tmux/rmux, shipping
multi-platform releases, triaging bot reviews, and auditing a large monorepo
in parallel.

Everything in here was learned the hard way: each rule traces back to a real
incident (a stale tag that shipped a release without its fix, a worker whose
uncommitted files were wiped by a sibling, a "recurring" bug that was actually
7 copies of the same logic).

## Install

```bash
claude plugin install https://github.com/rp4ri/orchestration-studio
# or load for one session:
claude --plugin-dir ./orchestration-studio
```

Skills are namespaced: `/orchestration-studio:director`, etc.

## Start here

**[WORKFLOW.md](WORKFLOW.md)** — the canonical end-to-end agent flow
(setup → dispatch → work → bot wait → triage → merge → release → monitor),
including the **worktree-per-worker isolation** procedure and the exact rules
that keep workers conflict-free.

**[skills/director/rmux-reference.md](skills/director/rmux-reference.md)** —
the rmux/tmux cheat sheet: every key combination and command (send-keys
sequence, capture-pane flags, the truncation-safe state grep, the watcher
loop), with the reason behind each flag.

## What's inside

### Skills (`skills/`)

| Skill | What it teaches Claude |
|---|---|
| **director** | The tmux/rmux director-workers pattern: worktree-per-worker, the exact send-keys protocol (Escape → C-u → literal → Enter), ghost-text hazards, truncation-safe WORKING/IDLE detection (`grep 'esc to'` + debounce), background watchers as the event loop, dispatch mandate templates |
| **pr-triage** | Bot-review discipline: the unanswered-comment jq query, fix-legit-or-justify, reply-with-SHA, merge gating on zero unanswered, merge ordering across many PRs |
| **release-train** | Tag-driven multi-platform releases with independent cadences (per-platform tag namespaces), safe re-tagging (verify tag→tip BEFORE pushing), `gh run watch` background watchers with built-in post-release verification, first-platform-build failure catalog (Windows spawn/cross-drive, Android Tauri ACL), auto-updater manifest safety |
| **audit-swarm** | Partitioned multi-agent audits: findings-only mandates, enumerable-inventory framing, uniform severity contract, consolidation into cross-cutting themes, rate-limit/filter recovery during swarms |
| **worker-recovery** | The failure taxonomy: rate-limit cuts, usage-policy false positives (and the defensive re-framing that passes), false-idle detection, the verify-artifact protocol (idle + missing artifact = incident), context-preservation rules |
| **bug-family-hunt** | Killing recurring bugs: git archaeology of previous fixes, instance enumeration, one shared resolver, the two-test rule (literal regression + anti-recurrence source-scan guard), sibling sweeps from a confirmed root cause |
| **consolidate** | Merging N CLEAN PRs through one integration branch: combined-state CI as the real gate, conflict→exclude-and-report, and the "`Closes #N` doesn't fire via an aux branch" sweep |
| **spec-discipline** | Diagnosis discipline: falsifiable-hypothesis specs (never conclusions), mandatory phase-0 data audit for state bugs, the two-shipped-fixes stop-rule with canonical-repro release gates, and the premise-challenger role against "CLEAN theater" |

### Agents (`agents/`)

| Agent | Role |
|---|---|
| **worker-monitor** | Read-only pane inspector: WORKING/IDLE/INCIDENT per pane, failure-signature detection, artifact verification. Never sends keys |
| **pr-triager** | Single-PR bot-review triage: unanswered observations table, LEGIT/REJECT classification with reasoning, merge-readiness verdict |

### Hooks (`hooks/hooks.json` + `scripts/`)

| Hook | Event | What it does |
|---|---|---|
| `tag-push-guard.sh` | PreToolUse(Bash) | When a `git push` carries a tag, warns if the tag's commit isn't contained in any remote-tracking branch — catches the stale-tag-ships-old-code incident before it happens |
| `leak-guard.sh` | PreToolUse(Bash) | Before a `git push`/release upload, scans the OUTGOING commits' added lines for secrets and infra identifiers — including **bare** public IPs (not just `ip:port`), instance ids, internal hostnames, private-key blocks, `.env`/`.pem` additions. Secret scanners miss identifiers; a too-narrow IP regex once let the real ones through |
| `symlink-guard.sh` | PreToolUse(Bash) | Before a `git commit`, flags staged symlinks (mode 120000) named `node_modules` or with absolute-path targets — a worker's broad `git add` once shipped them and broke Windows CI while macOS tolerated it |
| `detect-orchestration.sh` | SessionStart | Injects the live tmux/rmux session/pane map into context, with the "pane titles are stale" reminder |

## The five laws (if you read nothing else)

1. **One worker, one worktree.** Shared checkouts end with one worker's git
   surgery destroying another's uncommitted state.
2. **Never blind-Enter a pane.** Ghost text is not input. `C-u` first, always.
3. **Idle + missing artifact = incident.** A dead worker (rate limit, filter
   block) is indistinguishable from a finished one until you check what it was
   supposed to produce.
4. **Verify a tag points at the intended tip before pushing it.** A re-tag
   whose `git tag -d` silently failed will ship a release without its fix.
5. **A recurring bug is a pattern with N instances.** Fix the resolver once,
   then add the guard test that fails when instance N+1 is written.

## Provenance

Built from a live orchestration session over a production monorepo
(Electron desktop + SvelteKit UI + Node relay + Tauri mobile): ~20 PRs
authored/triaged/merged, 5 releases across 3 platforms, one prod outage
diagnosed and reverted, one 80+-finding parallel audit — all coordinated by a
director session driving 3 workers. The skills are the playbooks that session
converged on.

## License

MIT
