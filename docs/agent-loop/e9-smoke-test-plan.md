# E9 Smoke Test Plan

## Purpose

Verify the `agent-rebase.yml` conflict-resolution path end-to-end against
synthetic conflicts before enabling it on real consumer repositories.

---

## Scenario 1 — Happy path: synthetic conflict resolves, tests pass, PR becomes mergeable

**Goal:** Confirm the full green-path works.

### Setup

1. Create a base branch (`main`) with a file containing a known line, e.g.:
   ```
   # config.yml
   timeout: 30
   ```
2. Create two branches that both edit that line:
   - `feature-a`: changes `timeout` to `60`
   - `feature-b` (merges to `main` first): changes `timeout` to `45`
3. Merge `feature-b` into `main`.
4. Open a PR for `feature-a`. The PR is now `dirty` (conflict on the `timeout` line).

### Execution

Dispatch `agent-rebase.yml` for the `feature-a` PR with the consuming repo's
`build_command` and `test_command` set to commands that pass when `timeout` is
any positive integer.

### Expected outcomes

- [ ] `extract-conflict-context.sh` produces a conflict dossier with the single
  conflicting file and the ±20-line hunk.
- [ ] The conflict-resolver agent resolves the conflict, preferring the PR-branch
  value (`60`) as the incoming change.
- [ ] Build and test commands pass.
- [ ] The PR branch is pushed with `--force-with-lease` by `developer-bot`.
- [ ] The PR transitions from `dirty` to `clean` (mergeable_state).
- [ ] The reviewer workflow can subsequently approve and merge.

---

## Scenario 2 — Escalation path: agent resolution breaks a test, no push

**Goal:** Confirm the failure path does not push and correctly escalates.

### Setup

1. Same base setup as Scenario 1, but this time:
   - The test suite asserts `timeout == 60` (the PR-branch value).
   - The conflict-resolver is prompted with an ambiguous context so it is likely
     to pick the base-branch value (`45`) instead of the PR-branch value (`60`).

### Execution

Dispatch `agent-rebase.yml` for the PR. The test command is:
```bash
grep 'timeout: 60' config.yml
```
which exits non-zero when `timeout` is `45`.

### Expected outcomes

- [ ] Agent resolves the conflict (but picks wrong value, e.g. `45`).
- [ ] `test_command` exits non-zero.
- [ ] `git rebase --abort` is called; the PR branch is NOT pushed.
- [ ] PR is labeled `agent:needs-human`.
- [ ] A diagnostic PR comment is posted containing:
  - The conflicting file name.
  - A diff snippet of what the agent attempted.
  - Truncated test output (≤ 2000 characters).
- [ ] `mergeable_state` remains `dirty` (no change to the branch).

---

## Scenario 3 — Edit-surface check: agent edits outside conflict markers, resolution rejected

**Goal:** Confirm the post-resolution diff check catches out-of-scope edits.

### Setup

1. Same synthetic conflict as Scenario 1.
2. Inject a simulated agent response that, in addition to resolving the conflict
   marker, also reformats an unrelated comment line outside the conflict region.

### Execution

Replace the conflict-resolver agent step with a script that:
- Resolves the conflict marker correctly.
- Also edits one non-conflict line (e.g. changes `# config.yml` to `# Config`).

Then dispatch `agent-rebase.yml` normally.

### Expected outcomes

- [ ] `validate-conflict-resolution.sh` (or the equivalent post-resolution
  diff check in `agent-rebase.yml`) detects the out-of-region edit.
- [ ] `git rebase --abort` is called.
- [ ] PR is labeled `agent:needs-human`.
- [ ] A diagnostic PR comment is posted identifying which file had out-of-region
  edits and why the resolution was rejected.
- [ ] The PR branch is NOT pushed.

---

## Pass / fail criteria

All three scenarios must pass before `agent-rebase.yml` is enabled on any
consumer repository beyond `riddim-release` itself.

A scenario "passes" when every expected outcome listed above is confirmed by
manual inspection of the GitHub Actions run log and the PR state.

## Running the smoke tests

Use the `_smoke-test-e1.yml` / `_dev-self-test.yml` pattern already in this
repo: dispatch `agent-rebase.yml` with `self_test_mode: true` for guard wiring,
and with synthetic fixture repos for the full end-to-end scenarios above.

Record the Actions run URL and PR URL for each scenario in RIDDIM-137 comments
as evidence before marking E9 Done.
