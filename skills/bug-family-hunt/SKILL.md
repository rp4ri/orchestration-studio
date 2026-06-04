---
name: bug-family-hunt
description: >
  When a bug recurs ("we fixed this last week!") or a root cause is confirmed,
  hunt the ENTIRE family: find every surface with the same pattern, fix the
  root once with a shared resolver, and add an anti-recurrence guard so the
  pattern cannot be reintroduced. Use for recurring bugs, post-fix sweeps,
  and "why does this keep coming back" investigations.
---

# Bug Family Hunt — Kill the Pattern, Not the Instance

A bug that "comes back every week" was never one bug. It is a PATTERN with N
instances; every previous fix patched one instance. The tell: each past fix
looks correct, touches a different file, and the symptom reappears on the next
redesign.

## Step 1 — Archaeology before code

```bash
git log --oneline --all -i --grep "<symptom keyword>"
```

Read every previous fix for the same symptom. If they patched DIFFERENT call
sites for the same logical operation, you've confirmed a family: N copies of
the same logic, each rotting independently.

Production example: a display-name bug "fixed" 3 times — each fix patched one
UI surface. The hunt found **7 surfaces, each with its own copy of the fallback
chain** plus 3 divergent label maps. Every redesigned surface dropped a step
and regressed. The data layer was fine the whole time.

## Step 2 — Enumerate every instance

Grep for the pattern's signature, not the symptom:

```bash
git grep -n "<the repeated expression>" -- 'src/'   # e.g. the fallback chain, the un-targeted call
```

Build the full instance table (file:line → status). This is also how sibling
bugs surface: a confirmed root cause ("un-targeted RPCs go to an arbitrary
node") predicts its family — audit EVERY call of the same shape, not just the
reported one. In practice one confirmed routing bug predicted four more
(catalog fetch, archive list, session restore, entity CRUD), all confirmed.

## Step 3 — One shared resolver

Extract the logic into ONE function/module and migrate every instance to thin
wrappers over it. The fix is structural: after this, a new surface CANNOT
half-implement the logic — it imports the resolver or it doesn't work.

## Step 4 — Two tests, not one

1. **The literal bug**: a regression test asserting the exact reported case
   (input that used to render wrong → asserts the right output, AND asserts
   the wrong output is absent).
2. **The anti-recurrence guard**: a test that scans the source tree and FAILS
   if any file outside the resolver re-declares the pattern (the duplicate
   label map, the re-implemented fallback chain). This is the test that stops
   instance N+1 — the literal test only protects instance 1.

```ts
// guard sketch
const offenders = grepSource(/PROVIDER_LABELS|\.cyboName \?\?/)
  .filter((f) => f !== "src/lib/agent-display.ts");
expect(offenders).toEqual([]);
```

While adding the tests, check the package actually RUNS them in CI — a missing
`"test"` script means every existing test file was decorative.

## Step 5 — Sweep for siblings

Before closing: "what else has this shape?" Dispatch an audit (see
`audit-swarm`) scoped to the pattern — confirmed-family audits have the highest
signal-to-noise of any audit type. Fix CRITICAL siblings now; file the rest
with the family label so the next report matches instantly.

## Recurrence post-mortem checklist

- Why did fix #1 not catch all instances? (No enumeration step.)
- Why did new code re-introduce it? (No guard test, no shared resolver.)
- Why was it intermittent? (Nondeterminism — e.g. depends on connection order,
  cache state, or which replica answers — document the trigger condition.)
- Does the fix live where the NEXT person will look? (Resolver named after the
  domain concept, comment explaining the family history with PR numbers.)
