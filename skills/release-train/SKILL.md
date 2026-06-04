---
name: release-train
description: >
  Run tag-driven multi-platform releases (macOS / Windows / Android / server
  deploy) with independent cadences per platform, safe re-tagging after failed
  builds, background run watchers, and post-release verification. Use when
  cutting releases, debugging release CI failures, re-triggering a failed
  release build, or designing per-platform release pipelines.
---

# Release Train — Tag-Driven Multi-Platform Releases

## Design: one workflow, per-platform tag namespaces

Platforms ship on **independent cadences** by giving each its own tag pattern,
all handled by one workflow with `if:` guards per job:

```yaml
on:
  push:
    tags:
      - "app-v*"        # desktop release (+ server deploy)
      - "app-win-v*"    # Windows-only, separate cadence
      - "app-mobile-v*" # Android-only
jobs:
  build-macos:
    if: startsWith(github.ref_name, 'app-v')
  build-windows:
    if: startsWith(github.ref_name, 'app-win-v')
  deploy-server:
    needs: build-macos   # only the main train deploys the backend
```

Why: an expensive/rare platform (Windows on paid minutes, mobile) builds ONLY
when you push its tag — zero recurring cost — and never forces a backend
restart. Keep the **version number aligned with the main train** when the code
is the same (`app-win-v0.0.81` = same app as `app-v0.0.81`).

## Cutting a release (the safe sequence)

```bash
git fetch origin -q
TIP=$(git rev-parse origin/main)
git tag -a app-v0.0.84 "$TIP" -m "app-v0.0.84

- change one (#101)
- change two (#104)"
# VERIFY before pushing — this check has caught a stale tag pointing at an old commit:
TAGC=$(git rev-parse app-v0.0.84^{commit})
[ "$TAGC" = "$TIP" ] && git push origin app-v0.0.84 || echo "❌ tag != tip, NOT pushing"
```

The verify step exists because of a real incident: `git tag -d` failed silently
(tag didn't exist locally), the subsequent `git tag -a` failed ("already
exists"), and the push shipped an OLD tag → CI built a commit **without the
fix**. Always compare tag commit to intended tip before pushing.

## Re-triggering after a failed build

Only safe when **nothing was published** by the failed run (check the releases
repo / artifact store first):

```bash
gh run cancel <stale-run-id> -R <repo>          # if a wrong run is in flight
git push origin :refs/tags/app-win-v0.0.81      # delete remote tag
git tag -d app-win-v0.0.81                      # delete local tag (verify it succeeds!)
git tag -a app-win-v0.0.81 "$NEW_TIP" -m "… Attempt 2: includes <fix PR>."
# verify, then push
```

If artifacts WERE published, bump the version instead of re-tagging.

Also: **re-running a failed tag run re-uses the OLD workflow file**. If the fix
was to the workflow itself, a re-run won't pick it up — re-tag (or
`workflow_dispatch` from the default branch) instead.

## Watching runs (never poll in foreground)

```bash
# run_in_background=true — completion notification re-invokes you
gh run watch <run-id> -R <repo> --exit-status --interval 45 > /dev/null 2>&1
echo "🏁 $(gh run view <run-id> -R <repo> --json status,conclusion,jobs \
  -q '.status+"/"+(.conclusion//"?")+" | "+([.jobs[]|.name+"="+(.conclusion//.status)]|join(", "))')"
# on failure, append:
gh run view <run-id> -R <repo> --log-failed 2>&1 | grep -iE 'error|ENOENT|fail' | head -12
```

Bundle the **post-release verification into the watcher** so it runs the moment
the build finishes: check the published assets, hit the deployed service's
health endpoint, verify the auto-updater manifests.

## First-time platform builds: budget 2–4 attempts

Every new OS runner surfaces a class of portability bugs. Real examples:
- **Windows**: `spawnSync pnpm ENOENT` (pnpm is a `.cmd` shim — spawn needs
  `shell: process.platform === "win32"`); pnpm mangling **cross-drive** paths
  (`os.tmpdir()` on C: vs checkout on D: — deploy to a sibling dir of the repo
  instead); each extra arch ≈ 2× build time and upload.
- **Android (Tauri)**: `generate_context!` failing on capability permissions no
  plugin defines (`SetPermissionNotFound`) — the plugin's build.rs must generate
  its command permissions; validate with a host-side `cargo check` (no NDK needed).
- Treat each failure as: read `--log-failed` tail (not grep noise — the real
  error is usually the LAST error), fix root cause in a small PR, re-tag.

## Auto-updater safety (multi-platform, one releases repo)

electron-updater reads **per-OS manifests** (`latest-mac.yml` vs `latest.yml`):
a `--win`-only build emits only `latest.yml` and can never clobber the mac
manifest. Same releases repo is safe for all platforms; matching version
numbers land assets in the SAME release entry. Never pass `--mac` in the
Windows job; never enable `generateUpdatesFilesForAllChannels`.

## Server deploy in the train

- Gate the deploy on an actual server diff
  (`git diff $PREV $HEAD -- packages/server/ deploy/`) so UI-only releases skip
  the restart (no client disconnects).
- **Health-wait, not fixed sleep**: loop up to 30s checking
  `systemctl is-active` + HTTP health; dump `journalctl` tail INTO the CI log
  on failure. A startup crash must fail the deploy visibly, not leave prod
  silently crash-looping.
- Validate deploy-command changes **live on the host first** (run the exact
  install/restart command over SSH yourself), then encode them in the workflow.
- Know your host's dependency-resolution reality (e.g. a pnpm workspace
  resolves imports via the PACKAGE's manifest, and an install run in a non-
  workspace subdir silently ascends to the workspace root). Sync every manifest
  the runtime actually resolves against.
