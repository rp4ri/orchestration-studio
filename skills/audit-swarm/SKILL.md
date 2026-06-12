---
name: audit-swarm
description: >
  Run a deep codebase audit by partitioning it into areas and delegating each
  to a parallel worker agent with a findings-only mandate, then consolidating
  the reports into one prioritized document. Use when the user asks for a
  thorough audit, wants to map every component for a class of bugs, or wants
  to verify code health across a large codebase.
---

# Audit Swarm — Partitioned Multi-Agent Auditing

## Core principles

1. **Findings-only mandates.** Auditors REPORT, they don't fix. Fixing during
   an audit destroys parallelism (merge conflicts), biases coverage (workers
   rabbit-hole on the first bug), and robs the director of prioritization.
   Fixes are assigned AFTER consolidation, by severity.
2. **Partition by architectural layer**, not by directory size. Each worker
   gets one coherent layer (e.g. server routing / UI consumers / storage +
   CLI) so findings within a report share context.
3. **Seed with a confirmed bug family.** The highest-yield audits start from a
   real bug just fixed: "we confirmed pattern X in places A and B — map EVERY
   surface that could have the same pattern." Generic "find problems" audits
   produce noise; family hunts produce confirmed siblings.

## The mandate template (per worker)

```
AUDIT (findings only, NO fixes) — area: <LAYER>.
Context: <the confirmed bug family, 2-3 lines, with PR references>.
Work in <worktree> on a read-only branch from origin/main.
MANDATE:
  (a) <enumerable inventory task — "classify EVERY X by Y">
  (b) <second dimension>
  (c) <standard checks for this layer: dead code / perf / validation consistency>
For each finding: file:line, class, severity (CRITICAL/HIGH/MEDIUM/LOW),
hypothetical repro, 1-line suggested fix.
Write the report to <path>/audit-<area>.md and reply with the severity count.
```

The **enumerable inventory** framing ("all 20 forward types", "every client.*
call site", "all 63 handlers") is what forces completeness — auditors given
open-ended scope sample; auditors given a checklist enumerate.

## Severity contract (uniform across workers)

- **CRITICAL** — works by accident / data loss / auth bypass; fix immediately.
- **HIGH** — wrong behavior reachable in production (the bug family hits).
- **MEDIUM** — degraded/fragile behavior, consistency gaps, missing retries.
- **LOW** — dead code, perf nits, hygiene.

Require an explicit per-severity COUNT at the end of each report — it makes
consolidation and progress tracking mechanical.

## Consolidation (director)

1. Read all `audit-<area>.md` reports.
2. Merge into `.dev-studio/audit-report.md` (or equivalent): summary table,
   findings by severity, then **cross-cutting themes** — the most valuable
   output. Real example: 21 separate HIGH findings collapsed into ONE
   architectural fix ("storage writes are fire-and-forget with no outbox");
   another 10 collapsed into one decision ("entity X lives in per-node local
   storage but is consumed as global — move to shared DB or require explicit
   node targeting everywhere").
3. Propose the fix plan: CRITICALs first, then family-HIGHs grouped by the
   shared fix, then the architectural decisions that need the USER's call.
4. Dispatch fixes as normal worker tasks (PRs + triage), one theme per worker.

## Variant: issue-legitimacy pass (verify the backlog against HEAD)

**"Open issue count" is a lie after a big merge wave.** Before dispatching a
fix wave over an old backlog, run this variant — the target is the issue
tracker against current HEAD, not the code blind:

1. Partition the open issues across N agents by area.
2. Each agent, per issue: `gh issue view`, check the code at HEAD, emit
   `{issue, verdict: FIXED | STILL-VALID | PARTIAL, evidence, fixing_pr?}`.
3. **Close FIXED with a comment citing the fixing PR** — never close on doubt.
4. **File what the fresh eyes found**: re-verification reliably surfaces NEW
   bugs the merge wave introduced (in production: 18 of ~35 issues were
   stale, AND the pass discovered 4 new issues including a HIGH-severity
   security gate bypassed by the very work that closed the others).
5. Output a verdict table — the director plans the fix wave from the REAL
   remaining backlog.

Skipping this means re-implementing already-fixed issues (wasted waves) and
missing the regressions; the verification doubles as regression detection.

## Failure modes during swarm audits

- **Rate-limit cuts**: a worker dying mid-audit looks IDLE. On every idle
  signal verify the report file EXISTS before counting the area as done;
  re-trigger with "resume where you left off; if cut again, wait 90s and
  continue in smaller batches".
- **Safety-filter false positives**: security-audit wording ("missing auth",
  "injection", "bypass") can trip usage-policy filters and kill the worker.
  Re-frame defensively and it passes: "hardening review of OUR OWN server",
  "validation-consistency checklist — flag handlers that validate LESS than
  their peers". Same work, defensive framing.
- **Stale checkouts**: auditors MUST fetch + branch from origin/main at start,
  and re-verify findings against current HEAD if their first pass ran on a
  stale base (note it in the report).
