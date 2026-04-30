# E8 Smoke Test Plan

Smoke tests for RIDDIM-136 ([E8] Stale-PR detection + mechanical fast-forward rebase).

These scenarios must be executed manually on `riddim-release` itself during the
E6 pilot. Evidence (workflow run links, before/after screenshots, PR timeline)
must be linked as a comment on RIDDIM-136 and on RIDDIM-91.

**Prerequisites before running:**
- `DEV_BOT_PAT` org secret is set and granted to `riddim-release`.
- `developer-bot` has push access to PR branches on `riddim-release`.
- `rebase-watcher.yml` is wired to the push-on-base trigger in `riddim-release`'s own `agent-loop.yml`.
- The `autonomous` label exists on `riddim-release`.

---

## Scenario 1 — Behind PR auto-rebases within 2 minutes

**What it tests:** The primary path: a `behind`-state PR is detected by the
watcher and mechanically rebased without agent involvement.

### Setup

1. Create a throwaway branch off an older commit of `main` (at least one commit behind):

   ```bash
   git checkout -b smoke/e8-behind $(git log --oneline main | sed -n '3p' | awk '{print $1}')
   echo "# smoke test $(date)" >> docs/agent-loop/smoke-e8.md
   git add docs/agent-loop/smoke-e8.md
   git commit -m "chore: E8 smoke test — behind-state throwaway"
   git push -u origin smoke/e8-behind
   ```

2. Open a PR from `smoke/e8-behind` to `main` and apply the `autonomous` label.

3. Confirm the PR shows "This branch is out-of-date with the base branch"
   (i.e. `mergeable_state == "behind"`) in the GitHub UI.

### Trigger

Push a trivial commit to `main` (e.g. merge any pending PR, or push a no-op
commit via `git commit --allow-empty`).

### Expected outcome

Within 2 minutes of the push:

- The `rebase-watcher` workflow run on `riddim-release` completes with
  "Dispatching auto-rebase for PR #N…" in its log.
- The `auto-rebase` workflow run completes successfully.
- The PR's head SHA advances (a new `synchronize` event is visible in the PR
  timeline).
- The PR's base-branch divergence indicator disappears (GitHub shows the branch
  is up-to-date).
- `get-mergeable-state.sh` called manually for the PR returns `clean` (or
  `unstable` if CI now fails — that is E5 territory, not E8).
- **No agent was invoked** — no Claude Code session was launched, no
  `agent-rebase.yml` run appears.

### Evidence to capture

- Link to the `rebase-watcher` workflow run.
- Link to the `auto-rebase` workflow run.
- PR timeline screenshot showing the rebase commit by `developer-bot`.

---

## Scenario 2 — Dirty PR dispatched to E9 (no mechanical rebase attempted)

**What it tests:** The watcher correctly identifies a conflicting PR as `dirty`
and dispatches `agent-rebase.yml` (E9) without attempting a mechanical rebase.

### Setup

1. Create a branch that introduces a change that **conflicts** with a recent
   commit on `main`. For example, if `main` has recently changed line 1 of
   `README.md`, edit that same line differently on your branch.

   ```bash
   git checkout -b smoke/e8-dirty main~2  # start from two commits before current main
   # Edit a file that has changed on main since this point, to ensure conflict
   echo "CONFLICT $(date)" > README.md
   git add README.md
   git commit -m "chore: E8 smoke test — dirty-state throwaway"
   git push -u origin smoke/e8-dirty
   ```

2. Open a PR from `smoke/e8-dirty` to `main` and apply the `autonomous` label.

3. Confirm the PR shows a merge conflict indicator in the GitHub UI
   (`mergeable_state == "dirty"`).

### Trigger

Push to `main` (or wait for the 15-minute cron backstop to fire).

### Expected outcome

- The `rebase-watcher` workflow run logs "Dispatching agent-rebase (E9) for
  PR #N…".
- An `agent-rebase` workflow run is dispatched and appears in the Actions tab.
- **No `auto-rebase` workflow run is dispatched** — the mechanical rebase path
  is not attempted.
- The PR is not force-pushed by a mechanical rebase job.

### Evidence to capture

- Link to the `rebase-watcher` workflow run showing the `dirty` routing decision.
- Link to the dispatched `agent-rebase` workflow run.
- Confirmation that no `auto-rebase` run appeared for this PR number.

---

## Scenario 3 — Concurrent human push rejected by `--force-with-lease`

**What it tests:** If a human pushes to the PR branch between `git fetch` and
`git push --force-with-lease`, the rebase push is rejected and a diagnostic
comment is posted. No force-overwrite of the human's commit occurs.

This scenario is harder to reproduce deterministically because it requires a
timing race. The recommended approach is to pause the job mid-run using
`sleep` injection or GitHub's workflow debug mode, push a human commit during
the pause, and let the job resume.

Alternatively, test the failure branch directly by running `auto-rebase.yml`
via `workflow_dispatch` with an `pr_head_sha` that does not match the actual
current head of the PR branch (simulating a stale SHA).

### Setup

1. Create a behind-state PR as in Scenario 1 (steps 1–3).

2. Manually dispatch `auto-rebase.yml` on `riddim-release` via `workflow_dispatch`
   with:
   - `consumer_repo`: `RiddimSoftware/riddim-release`
   - `pr_number`: the PR number from step 1
   - `pr_head_sha`: any SHA that is **not** the current head of the PR branch
     (e.g. use the SHA before your last commit)
   - `pr_branch`: the branch name
   - `base_branch`: `main`

### Expected outcome

- The workflow run fails (exit 1).
- A comment is posted on the PR with diagnostic output explaining the
  force-with-lease rejection.
- The PR branch is **unchanged** — no force-overwrite occurred.
- The PR is labeled `agent:rebase-failed`.
- No data loss occurs on the PR branch.

### Evidence to capture

- Link to the `auto-rebase` workflow run showing the non-zero exit.
- Screenshot of the diagnostic comment on the PR.
- Confirmation of the `agent:rebase-failed` label on the PR.
- PR branch head SHA before and after (should be identical).

---

## Reporting results

Once all three scenarios pass, post a comment on RIDDIM-136 with:

```
E8 smoke tests complete.

Scenario 1 (behind → auto-rebase): <workflow run URL>
Scenario 2 (dirty → E9 dispatch): <workflow run URL>
Scenario 3 (force-with-lease rejection): <workflow run URL>

All three scenarios passed. E8 is ready for E6 pilot onboarding.
```

Also post a summary comment on RIDDIM-91 linking these results as evidence of
the autonomous-merge pipeline's stale-PR handling.
