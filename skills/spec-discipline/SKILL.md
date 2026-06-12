---
name: spec-discipline
description: >
  Diagnosis discipline for a director dispatching bug work to workers:
  falsifiable-hypothesis specs (never conclusions), a mandatory phase-0 data
  audit for state/persistence bugs, the two-fixes stop-rule with a canonical
  repro as the release gate, and the premise-challenger role in
  cross-validation. Use when writing bug specs for workers, when a bug
  survives shipped fixes, or when reviews keep coming back CLEAN while the
  user still sees the symptom.
---

# Spec Discipline — Don't Multiply a Wrong Diagnosis ×N Workers

Workers execute excellently. When the director's diagnosis is wrong, a fleet
of N produces **correct code for incorrect framings**, N times in parallel —
a production saga shipped 5+ releases that way, each one CLEAN, none fixing
the user's symptom. These four rules are the antidote, in the order they
apply.

## 1. Specs carry falsifiable hypotheses, never conclusions

The anti-pattern: specs with the director's inference embedded as fact
("the backend is contended", "it's a stale build", "switch the install to
package X"). The worker can't push back on what's framed as ground truth.

Every bug spec uses this shape — and the worker MUST be able to refute the
director:

```
SYMPTOM:    the observable, literal (exact error message, screenshot)
EVIDENCE:   what was VERIFIED with data (logs, queries, fingerprints) — kept
            separate from…
HYPOTHESES: ranked and FALSIFIABLE — h1, h2, h3, each with the experiment
            that would refute it
MANDATE:    step 1 = confirm/refute the hypotheses BEFORE writing code.
            If all of them fall, REPORT the finding — do not implement
            "something".
DONE:       the user's repro passes (not "typecheck 0 + tests green")
```

Violation tell: the spec says "because" followed by something nobody
verified. That's a conclusion wearing a hypothesis's clothes — rewrite it
with its experiment.

## 2. Phase-0 data audit (state/persistence bugs)

A "not found" bug survived 5+ correct-looking fixes because the production
table was **empty** — creation never wrote to the cloud. A single
`SELECT * FROM <table>` on day 1 would have ended the saga; nobody ran it
because every delegated task was *code-reading*.

- For any bug involving state, persistence, or sync, the FIRST delegated
  task is: **"where does the data physically live?"** — real queries against
  every store (each daemon's SQLite, production PG, disk), results in a
  table. Fixes are delegated only after. *One query against production beats
  ten code reads.*
- The director maintains an **evidence map**: which machine holds which logs,
  SSH keys, DB access, provider creds. A failed access attempt ("no key for
  X") is a ROUTING problem, not a dead-end — delegate the collection to the
  agent that IS where the evidence is. A worker reporting "couldn't access X,
  moving to next hypothesis" means the director must route the access, not
  accept the surrender.

## 3. Stop-rule: two shipped fixes → freeze + task-force

The same user-reported symptom surviving **2 shipped fixes** means the
incremental-fix loop is peeling layers of the wrong onion (a real symptom
survived 5 releases, each "one more fix" passing typecheck+tests+CLEAN
cross-val). The reflex to ship a third is debt:

- **FREEZE incremental fixes.** Dispatch a task-force of N workers on
  independent, mutually exclusive angles: the DATA (phase-0 audit), the
  DEPLOYMENT (versions/tiers actually running), the full E2E TRACE of the
  failing path, and a LIVE REPRO. When this was finally done, the real cause
  surfaced in one pass.
- **Release gate = the canonical repro, not tests.** Keep ONE executable
  repro per user bug (command/script that reproduces the symptom). The
  release claiming the fix re-runs THAT — "tests pass" is not the gate. If
  the fleet can't run the repro (creds on another machine), the gate is a
  deterministic replay-test of the real output PLUS the user's confirmation
  BEFORE declaring it resolved.

## 4. Premise-challenger (the anti-"CLEAN theater" role)

Standard cross-validation checks the diff against the spec — so when the spec
inherits a false premise from the director, the review faithfully **certifies
the error** (production case: 8 PRs cross-validated CLEAN, all built on a
premise a single query disproved). Maximum confidence, minimum truth.

In every cross-validation cycle, ONE reviewer gets a different mandate:

- Do NOT review the diff line-by-line (the normal reviewers do that).
- Attack the spec's ASSUMPTIONS: was "X exists / works / lives in Y" verified
  with data or inherited? Does the bug this claims to fix have a repro this
  change demonstrably kills?
- Verdict is about the FRAMING: `premises verified` or
  `premise N unverified — verify before merge`.

This is rule 1's filter applied at the exit: hypotheses in, challenged
premises out.
