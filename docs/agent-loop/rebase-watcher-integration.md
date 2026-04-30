# Rebase Watcher Integration Guide

This guide explains how consuming repositories add the push-on-base and
15-minute cron triggers that activate the E8 stale-PR detection and routing
loop, and documents the dispatch inputs required by `auto-rebase.yml` (E8)
and `agent-rebase.yml` (E9).

---

## 1. Adding the rebase watcher to a consumer repo

The recommended approach is to add a `rebase-watcher` job to the consuming
repo's existing `agent-loop.yml`. The job fires on every push to the protected
base branch and on a 15-minute cron backstop.

```yaml
# In <consumer-repo>/.github/workflows/agent-loop.yml
# Add under the `jobs:` key alongside the existing developer/reviewer jobs.

  rebase-watcher:
    # Fire on push to main (primary trigger) and on cron backstop.
    if: >-
      github.event_name == 'push' ||
      github.event_name == 'schedule'
    uses: RiddimSoftware/riddim-release/.github/workflows/rebase-watcher.yml@main
    with:
      consumer_repo: ${{ github.repository }}
      base_branch: main          # default; omit if your base branch is 'main'
      autonomous_label: autonomous  # default; omit unless you use a different label
    secrets:
      dev_bot_pat: ${{ secrets.DEV_BOT_PAT }}
```

Ensure the `on:` block of your `agent-loop.yml` already includes:

```yaml
on:
  push:
    branches: [main]         # primary: fires immediately after every merge to main
  schedule:
    - cron: '*/15 * * * *'  # backstop: catches push-trigger gaps
```

The `push` trigger provides near-real-time detection (< 1 minute in normal
load). The cron sweep catches cases where the push event was dropped (GitHub
Actions outages, rapid cascading merges) and ensures stale PRs are eventually
resolved.

### Required org secret

`DEV_BOT_PAT` must be an org-level secret granted to the consumer repo. It
requires the following permissions on the consumer repo:

- `contents: write` — to force-push the rebased branch
- `pull_requests: write` — to post diagnostic comments and apply labels
- `actions: write` — to dispatch `auto-rebase.yml` and `agent-rebase.yml`
  on `riddim-release`

---

## 2. `auto-rebase.yml` dispatch inputs (E8 — mechanical rebase)

`auto-rebase.yml` is dispatched by the watcher when `mergeable_state == "behind"`.
It is a `workflow_call` / `workflow_dispatch` hybrid in `riddim-release`.

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `consumer_repo` | string | yes | — | Owner/repo of the consumer (e.g. `RiddimSoftware/epac`) |
| `pr_number` | number | yes | — | Pull request number to rebase |
| `pr_head_sha` | string | yes | — | Expected PR head SHA; used for `--force-with-lease` to prevent clobbering concurrent pushes |
| `pr_branch` | string | yes | — | PR head branch name (e.g. `feature/RIDDIM-99-foo`) |
| `base_branch` | string | no | `main` | Target base branch |

Secret required: `dev_bot_pat` (passed through from the caller).

The concurrency group is `auto-rebase-<consumer_repo>-<pr_number>` with
`cancel-in-progress: true`. If `main` advances mid-rebase, the new watcher
run cancels the in-flight job and restarts.

A `behind`-state rebase that produces conflicts is treated as a watcher
classification bug. The job aborts, labels the PR `agent:rebase-failed`, posts
a diagnostic comment, and exits non-zero. It does **not** fall through to E9.

---

## 3. `agent-rebase.yml` dispatch inputs (E9 — agent conflict resolution)

`agent-rebase.yml` is dispatched by the watcher when `mergeable_state == "dirty"`.
It is implemented in E9 (`RiddimSoftware/riddim-release/.github/workflows/agent-rebase.yml@main`).

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `consumer_repo` | string | no | `""` (uses calling repo) | Owner/repo of the consumer |
| `pr_number` | number | yes | — | Pull request number with conflicts |
| `base_branch` | string | no | `main` | Target base branch |
| `build_command` | string | no | `""` | Optional build command to verify resolution compiles |
| `test_command` | string | no | `""` | Optional test command to verify resolution passes |
| `rebase_max_attempts` | number | no | `3` | Maximum agent resolution attempts before giving up |
| `rebase_max_files` | number | no | `8` | Max conflicting files before escalating to human |
| `rebase_max_lines` | number | no | (see workflow) | Max conflicting lines before escalating to human |

Secret required: `dev_bot_pat`.

---

## 4. Pre-merge re-check pattern (for E3)

Before enabling auto-merge on a PR, the reviewer workflow should re-query
`mergeable_state` to guard against a race where `main` advanced between the
reviewer's approval decision and the auto-merge enablement.

Pattern:

```bash
# In the reviewer workflow, before calling enable-auto-merge.sh:
state="$(GH_REPO="$CONSUMER_REPO" \
  riddim-release/.github/scripts/get-mergeable-state.sh "$PR_NUMBER" "$CONSUMER_REPO")"

case "$state" in
  clean)
    # Safe to enable auto-merge — proceed.
    ;;
  behind)
    # Main advanced; dispatch auto-rebase and abort this reviewer run.
    # The synchronize event from the rebase will re-trigger the reviewer.
    gh workflow run auto-rebase.yml \
      --repo RiddimSoftware/riddim-release \
      --field consumer_repo="$CONSUMER_REPO" \
      --field pr_number="$PR_NUMBER" \
      --field pr_head_sha="$CURRENT_HEAD_SHA" \
      --field pr_branch="$PR_BRANCH" \
      --field base_branch="$BASE_BRANCH"
    echo "PR is behind; dispatched auto-rebase. Reviewer will re-run after synchronize."
    exit 0
    ;;
  dirty)
    # Conflicts detected; dispatch agent-rebase (E9) and abort.
    gh workflow run agent-rebase.yml \
      --repo RiddimSoftware/riddim-release \
      --field consumer_repo="$CONSUMER_REPO" \
      --field pr_number="$PR_NUMBER" \
      --field base_branch="$BASE_BRANCH"
    echo "PR is dirty; dispatched agent-rebase (E9). Escalating."
    exit 1
    ;;
  blocked|unstable|unknown)
    echo "::warning::mergeable_state=${state}; not enabling auto-merge. Cron will retry."
    exit 1
    ;;
esac
```

The `get-mergeable-state.sh` helper polls until `mergeable != null` (up to
6 attempts × 5 s = 30 s) before returning the state. This covers GitHub's
asynchronous `mergeable` recomputation window.
