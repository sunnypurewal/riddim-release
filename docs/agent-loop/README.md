# Autonomous PR Loop — Onboarding Guide

> **Last verified against `riddim-release@4eb3b6e` on 2026-04-30.**
> Update this header whenever a material workflow change lands in riddim-release.

**Goal:** enroll a new consumer repo in < 30 minutes.

---

## Overview

The autonomous PR loop handles the full developer → review → merge cycle without human intervention for routine changes. Three actors collaborate:

1. **Developer bot** (`developer-bot`) — triggered by an `agent:build` label on an issue. Opens a PR implementing the issue body as acceptance criteria.
2. **Reviewer bot** (`reviewer-bot`) — triggered when the developer bot opens or updates a PR. Reviews the diff against acceptance criteria and either approves + enables auto-merge, or requests changes.
3. **GitHub auto-merge** — merges the PR once the `reviewer-agent-passed` required status check passes and all branch protection rules are satisfied.
4. **Rebase guard** (`agent-rebase.yml`) — keeps autonomous PRs current with `main`, fast-forwards cleanly stale PRs, and escalates conflicts that exceed attempt, size, or CODEOWNERS safety caps.

The reusable workflows live in this repo (`RiddimSoftware/riddim-release`) and are called from a thin trigger wrapper in each consumer repo.

---

## Prerequisites (E1 must be complete)

Before enrolling a consumer repo, confirm all of the following are in place at the org level:

- [ ] Org secrets set: `CLAUDE_CODE_OAUTH_TOKEN`, `REVIEWER_BOT_PAT` — see `docs/agent-loop/e1-checklist.md`
- [ ] GitHub Apps installed at org scope: `developer-bot` and `reviewer-bot`
- [ ] `RiddimSoftware/riddim-release` is on `main` with the reusable workflows present:
  - `.github/workflows/developer.yml`
  - `.github/workflows/reviewer.yml`

If any of these are missing, complete E1 first. Proceeding without them will result in silent workflow failures.

---

## Step-by-step enrollment (< 30 min)

### Step 1 — Copy the trigger wrapper workflow

Copy `docs/agent-loop/trigger-wrapper-template.yml` from this repo into the consumer repo at:

```
<consumer-repo>/.github/workflows/agent-loop.yml
```

Commit and push to `main`. No edits needed — the template is ready to use as-is. See the [template file](trigger-wrapper-template.yml) for the full content.

### Step 2 — Run the enrollment script

```bash
# From riddim-release root:
bash scripts/enroll-repo.sh <owner/repo>

# Example:
bash scripts/enroll-repo.sh RiddimSoftware/epac
```

The script:
- Creates all `agent:*` labels on the consumer repo
- Prints the branch protection settings URL and the exact settings required
- Verifies `CLAUDE_CODE_OAUTH_TOKEN` is accessible to the repo
- Prints a checklist of remaining manual steps

### Step 3 — Configure branch protection

The script cannot set all branch protection options via the API. Open the URL it prints and apply these settings manually on the `main` branch:

| Setting | Value |
|---|---|
| Require a pull request before merging | Yes |
| Required approving reviews | 1 |
| Require status checks to pass | Yes |
| Required status check name | `reviewer-agent-passed` |
| Require branches to be up to date | Yes |
| Allow auto-merge | Yes |
| Automatically delete head branches | Yes |

### Step 4 — Add CODEOWNERS

Create `<consumer-repo>/CODEOWNERS` covering high-risk paths. At minimum:

```
# Secrets and credentials
.env*                   @<your-github-handle>
**/.env*                @<your-github-handle>

# Release pipelines
fastlane/               @<your-github-handle>
.github/workflows/      @<your-github-handle>

# Infrastructure / cloud config
terraform/              @<your-github-handle>
infra/                  @<your-github-handle>

# Authentication
**/auth/                @<your-github-handle>
```

Adjust paths to match the consumer repo's structure. CODEOWNERS ensures a human must approve any PR touching these paths — the reviewer bot cannot self-approve them.

### Step 5 — Verify with a test PR

1. Create a test issue in the consumer repo with a clear, simple acceptance criterion (e.g., "Add a comment to README.md explaining that the autonomous PR loop is active").
2. Add the `agent:build` label to the issue.
3. Watch the Actions tab — the developer workflow should run within ~30 seconds and open a PR.
4. The reviewer workflow should trigger automatically on PR open.
5. If the reviewer approves, auto-merge should land within minutes.

Positive smoke test passed when: PR opened → reviewed → merged without human intervention.

Negative smoke test: On a separate test PR, temporarily remove `reviewer-agent-passed` from required checks, add the label `agent:pause` to a PR, and confirm the reviewer workflow does not run.

---

## The `agent:*` label set

| Label | Color | Purpose |
|---|---|---|
| `agent:build` | `#fb8c00` | Triggers the developer workflow on an issue |
| `agent:pause` | `#6a737d` | Halts all autonomous workflows on a PR or issue |
| `agent:needs-human` | `#d73a4a` | Applied when attempt cap is hit; blocks automation |
| `agent:attempt-1` | `#ffd8a8` | Attempt counter — first attempt |
| `agent:attempt-2` | `#ffb56b` | Attempt counter — second attempt |
| `agent:attempt-3` | `#ff922b` | Attempt counter — third attempt (final default) |
| `agent:rebase-attempt-1` | `#c5def5` | Rebase counter — first stale-PR rebase attempt |
| `agent:rebase-attempt-2` | `#8db7e8` | Rebase counter — second stale-PR rebase attempt |
| `agent:rebase-attempt-3` | `#5319e7` | Rebase counter — third stale-PR rebase attempt |
| `agent:codeowners-veto` | `#b60205` | Rebase guard blocked conflicts in human-owned CODEOWNERS paths |

The `enroll-repo.sh` script creates all of these with the correct colors.

## Stale PR rebase defaults

`agent-rebase.yml` is the reusable stale-PR recovery path. A consumer-side watcher should call it for open `autonomous` PRs after `main` advances or on a cron backstop.

Default guard thresholds:

| Setting | Default | Purpose |
|---|---:|---|
| `REBASE_MAX_ATTEMPTS` | `3` | Stop retry loops after three total rebase attempts |
| `REBASE_MAX_FILES` | `8` | Escalate large conflict surfaces |
| `REBASE_MAX_LINES` | `200` | Escalate conflicts with too many marker lines |

Guard comments use fixed markers: `<!-- riddim:rebase-guard:attempts -->`, `<!-- riddim:rebase-guard:size -->`, and `<!-- riddim:rebase-guard:codeowners -->`.

---

## Kill switches

### `agent:pause`

Add the `agent:pause` label to any PR or issue to immediately halt autonomous processing. The trigger wrapper checks for this label before calling the reusable workflows; runs in progress are not cancelled (GitHub Actions does not support that via labels), but no new runs will start.

Remove the label to re-enable automation.

### `agent:needs-human`

Applied automatically by the developer workflow when the attempt cap is reached (default: 3 attempts via `agent:attempt-1` through `agent:attempt-3`). Once applied:
- No further developer or reviewer runs start
- A human must review the PR manually
- Remove `agent:needs-human` and all `agent:attempt-*` labels to reset the counter and allow the loop to resume

---

## Failure runbook

See [`failure-runbook.md`](failure-runbook.md) for diagnosis and recovery steps covering:
- Reviewer stuck in a loop
- Attempt cap hit
- `reviewer-agent-passed` check blocked (runner outage)
- riddim-release `main` broken (blast radius: all consumers)

---

## Related resources

- [`e1-checklist.md`](e1-checklist.md) — org-level prerequisites
- [`trigger-wrapper-template.yml`](trigger-wrapper-template.yml) — copy into consumer repos
- [`scripts/enroll-repo.sh`](../../scripts/enroll-repo.sh) — per-repo enrollment automation
- [RIDDIM-91](https://riddim.atlassian.net/browse/RIDDIM-91) — parent initiative
