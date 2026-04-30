# Autonomous PR Loop — Onboarding Guide

> **Last verified against `riddim-release@026e10a` on 2026-04-30.**
> Update this header whenever a material workflow change lands in riddim-release.

**Goal:** enroll a new consumer repo in the autonomous PR loop in < 30 minutes.

---

## Overview

The autonomous PR loop handles the full developer → review → merge cycle without human intervention for routine changes. Three actors collaborate:

1. **Developer bot** (`developer-bot`) — triggered by an `agent:build` label on an issue. Opens a PR implementing the issue body as acceptance criteria.
2. **Reviewer bot** (`reviewer-bot`) — triggered when the developer bot opens or updates a PR. Reviews the diff and either approves + enables auto-merge, or requests changes.
3. **GitHub auto-merge** — merges the PR once the `reviewer-agent-passed` required status check passes and all branch protection rules are satisfied.
4. **Rebase guard** (`agent-rebase.yml`) — keeps autonomous PRs current with `main`, fast-forwards cleanly stale PRs, and escalates conflicts that exceed attempt, size, or CODEOWNERS safety caps.

The reusable workflows live in `RiddimSoftware/riddim-release` and are called from a thin trigger wrapper in each consumer repo.

---

## Step 1 — Confirm this loop owns the repo (not prconverged)

Before enrolling, confirm that the target repo is leaving the `prconverged` pipeline and moving to the RIDDIM-91 autonomous loop.

**Check for `prconverged` enrollment:**

```bash
# Is the repo currently using prconverged?
gh api repos/<owner>/<repo>/contents/.github/workflows \
  --jq '.[].name' | grep -i prconverged

# Check org-level prconverged config (if applicable)
gh api orgs/RiddimSoftware/actions/secrets --jq '.secrets[].name' | grep -i prconverged
```

**Allocation rules:**
- A repo must use either prconverged **or** the RIDDIM-91 loop — not both.
- If prconverged is present, remove or disable it before enrolling.
- Note in the ticket/PR that prconverged was removed and by whom.

> **Why this matters:** Both pipelines attempt auto-merge. Running both causes race conditions and double-review noise.

---

## Step 2 — Grant org-secrets and bot-app access

The consumer repo must be granted access to the org-level secrets and have the GitHub Apps installed.

### 2a — Org secrets

Verify that the following org secrets are accessible to the new repo. A repo admin or org owner must grant access in **Settings → Secrets and variables → Actions → Organization secrets**:

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` |
| `DEV_BOT_PAT` | PAT token used by `developer.yml` workflow |
| `REVIEWER_BOT_PAT` | PAT token used by `reviewer.yml` workflow |

```bash
# Check which secrets the repo can currently access (org-level only):
gh api repos/<owner>/<repo>/actions/organization-secrets --jq '[.secrets[].name]'
```

If any are missing, a GitHub org admin must grant repository access at:
`https://github.com/organizations/RiddimSoftware/settings/secrets/actions`

To avoid replacing existing repository grants, add each repo with the per-repo endpoint:

```bash
CONSUMER="RiddimSoftware/your-repo"
CONSUMER_ID="$(gh api /repos/${CONSUMER} --jq .id)"

for SECRET in CLAUDE_CODE_OAUTH_TOKEN DEV_BOT_PAT REVIEWER_BOT_PAT; do
  gh api \
    --method PUT \
    "/orgs/RiddimSoftware/actions/secrets/${SECRET}/repositories/${CONSUMER_ID}"
done
```

### 2b — GitHub App installation

Confirm `developer-bot` and `reviewer-bot` are installed at org scope with access to the new repo:

```bash
# List app installations for the org
gh api orgs/RiddimSoftware/installations --jq '.installations[].app_slug'

# Confirm both apps have repository access
gh api "app/installations/<installation_id>/repositories" \
  --jq '.repositories[].full_name' | grep <repo-name>
```

If the apps are not installed on the repo, go to:
`https://github.com/organizations/RiddimSoftware/settings/installations`
→ find each bot → "Configure" → add the new repo.

---

## Step 3 — Add the trigger wrapper workflow

Copy the trigger wrapper into the consumer repo:

```bash
# From the riddim-release repo root, copy the template:
gh api repos/RiddimSoftware/riddim-release/contents/docs/agent-loop/trigger-wrapper-template.yml \
  --jq '.content' | base64 -d > /tmp/agent-loop.yml

# Add it to the consumer repo
cp /tmp/agent-loop.yml <path-to-consumer-repo>/.github/workflows/agent-loop.yml
```

The template is reproduced here for reference — **use the canonical file from `docs/agent-loop/trigger-wrapper-template.yml`**, not this copy, in case it has been updated:

```yaml
name: Autonomous PR Loop

on:
  issues:
    types: [labeled]
  pull_request:
    types: [opened, synchronize, ready_for_review]
  pull_request_review:
    types: [submitted]
  push:
    branches: [main]
  schedule:
    - cron: "*/15 * * * *"

jobs:
  developer:
    if: >-
      github.event_name == 'issues' &&
      github.event.action == 'labeled' &&
      github.event.label.name == 'agent:build' &&
      !contains(github.event.issue.labels.*.name, 'agent:pause') &&
      !contains(github.event.issue.labels.*.name, 'agent:needs-human')
    uses: RiddimSoftware/riddim-release/.github/workflows/developer.yml@main
    with:
      trigger_type: issue_labeled
      issue_number: ${{ github.event.issue.number }}
      issue_body: ${{ github.event.issue.body }}
    secrets: inherit

  developer-fixup:
    if: >-
      github.event_name == 'pull_request_review' &&
      github.event.review.state == 'changes_requested' &&
      github.event.review.user.login == 'reviewer-bot' &&
      !contains(github.event.pull_request.labels.*.name, 'agent:pause') &&
      !contains(github.event.pull_request.labels.*.name, 'agent:needs-human')
    uses: RiddimSoftware/riddim-release/.github/workflows/developer.yml@main
    with:
      trigger_type: changes_requested
      issue_number: ${{ github.event.pull_request.number }}
      pr_number: ${{ github.event.pull_request.number }}
      review_comments: ${{ github.event.review.body }}
    secrets: inherit

  reviewer:
    if: >-
      github.event_name == 'pull_request' &&
      (github.event.action == 'opened' || github.event.action == 'synchronize' || github.event.action == 'ready_for_review') &&
      github.event.pull_request.user.login == 'developer-bot' &&
      github.event.sender.login != 'reviewer-bot' &&
      !contains(github.event.pull_request.labels.*.name, 'agent:pause') &&
      !contains(github.event.pull_request.labels.*.name, 'agent:needs-human')
    uses: RiddimSoftware/riddim-release/.github/workflows/reviewer.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number }}
    secrets: inherit
```

Commit `agent-loop.yml` to `main` of the consumer repo before continuing.

---

## Step 4 — Configure branch protection on `main`

Branch protection must require `reviewer-agent-passed` so that PRs cannot merge without the reviewer completing its check. Run the enrollment script to print the settings URL and verify secrets:

```bash
# From the riddim-release root:
bash scripts/enroll-repo.sh <owner/repo>

# Example:
bash scripts/enroll-repo.sh RiddimSoftware/epac
```

If you need to apply just the status-check requirement from CLI while preserving all other branch-protection settings:

```bash
CONSUMER="RiddimSoftware/your-repo"
export CONSUMER

CURRENT_CHECKS="$(mktemp)"
export CURRENT_CHECKS
if ! gh api /repos/${CONSUMER}/branches/main/protection/required_status_checks > "${CURRENT_CHECKS}"; then
  cat > "${CURRENT_CHECKS}" <<'EOF'
{"strict": true, "contexts": []}
EOF
fi

python3 - <<'PY'
import json
import subprocess
import os

consumer = os.environ["CONSUMER"]
with open(os.environ["CURRENT_CHECKS"], "r", encoding="utf-8") as f:
    checks = json.load(f)

contexts = checks.get("contexts", [])
if "reviewer-agent-passed" not in contexts:
    contexts.append("reviewer-agent-passed")

payload = {
    "strict": checks.get("strict", True),
    "contexts": contexts,
}

subprocess.run(
    [
        "gh", "api", "--method", "PATCH",
        f"/repos/{consumer}/branches/main/protection/required_status_checks",
        "--input", "-",
    ],
    input=json.dumps(payload).encode("utf-8"),
    check=True,
)
PY

rm -f "${CURRENT_CHECKS}"
```

The script cannot set all branch protection options via the API. Open the URL it prints and apply these settings manually on the `main` branch:

| Setting | Value |
|---|---|
| Require a pull request before merging | ✅ Yes |
| Required approving reviews | 1 |
| Require status checks to pass before merging | ✅ Yes |
| Required status check name | `reviewer-agent-passed` |
| Require branches to be up to date before merging | ✅ Yes |
| Allow auto-merge | ✅ Yes |
| Automatically delete head branches | ✅ Yes |

> **`reviewer-agent-passed` is the critical gate.** Without it, PRs can merge before the reviewer finishes. With it, a runner/Anthropic outage blocks all merges — see `failure-runbook.md` for the manual override procedure.

---

## Step 5 — Author CODEOWNERS for high-risk paths

Create `<consumer-repo>/CODEOWNERS` covering paths that should require a human approver even when the reviewer bot approves the rest of the PR. CODEOWNERS entries override bot-only approval for matching files.

Checklist of high-risk path categories to cover:

- [ ] **Secrets and credentials** — `.env*`, `**/.env*`, `**/*secret*`, `**/*credential*`
- [ ] **Release pipelines** — `fastlane/`, `.github/workflows/`, `Makefile`, `scripts/release*`
- [ ] **Infrastructure and cloud config** — `terraform/`, `infra/`, `k8s/`, `docker-compose*`
- [ ] **Authentication** — `**/auth/`, `**/authentication/`, `**/*Auth*`

Minimum recommended `CODEOWNERS`:

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

Adjust paths to match the repo's actual directory structure. CODEOWNERS ensures a human must approve any PR touching these paths — the reviewer bot cannot self-approve them.

---

## Step 6 — Create the `agent:*` label set

All `agent:*` labels must exist on the consumer repo. The enrollment script creates them:

```bash
bash scripts/enroll-repo.sh <owner/repo>
```

If you prefer to create them manually, here is the full label set:

| Label | Hex color | Purpose |
|---|---|---|
| `agent:build` | `#fb8c00` | Triggers the developer workflow on an issue |
| `agent:pause` | `#6a737d` | Halts all autonomous workflows on a PR or issue |
| `agent:needs-human` | `#d73a4a` | Applied when attempt cap is hit; blocks automation |
| `agent:attempt-1` | `#ffd8a8` | Attempt counter — first attempt |
| `agent:attempt-2` | `#ffb56b` | Attempt counter — second attempt |
| `agent:attempt-3` | `#ff922b` | Attempt counter — third attempt (final default) |
| `agent:rebase-attempt-1` | `#c5def5` | Rebase counter — first stale-PR rebase |
| `agent:rebase-attempt-2` | `#8db7e8` | Rebase counter — second stale-PR rebase |
| `agent:rebase-attempt-3` | `#5319e7` | Rebase counter — third stale-PR rebase |
| `agent:codeowners-veto` | `#b60205` | Rebase guard blocked; conflicting files are human-owned |

---

## Step 7 — Run the manual smoke test

With enrollment complete, run both a positive and a negative smoke test before treating the repo as production-enrolled.

### Positive smoke test

1. Create a test issue in the consumer repo with a clear, simple acceptance criterion. Example body:
   ```
   Add a one-line comment to README.md that reads:
   `<!-- Autonomous PR loop is active on this repo -->`
   ```
2. Add the `agent:build` label to the issue.
3. In the Actions tab, confirm the `Autonomous PR Loop` workflow starts within ~30 seconds.
4. Wait for the developer job to finish and open a PR.
5. Confirm the reviewer job starts automatically on PR open.
6. If the reviewer approves, watch auto-merge land the PR to `main`.

**Positive smoke test passes when:** issue labeled → PR opened by developer-bot → reviewer-bot approves → PR auto-merged, without any human action.

### Negative smoke test

Confirm that the `reviewer-agent-passed` branch protection gate actually blocks merges when the check is absent.

1. Temporarily remove `reviewer-agent-passed` from required status checks on `main` (undo after the test).
2. Open a draft PR from any branch. Confirm the merge button is **not** blocked by the status check.
3. Re-add `reviewer-agent-passed` as a required check.
4. Open a new PR. Before the reviewer runs, confirm the **Merge** button shows "Some checks haven't run yet" or similar — confirming the gate is enforced.
5. Let the reviewer run to completion and confirm the PR becomes mergeable.

**Negative smoke test passes when:** `reviewer-agent-passed` absence visibly blocks the merge button.

---

## Step 8 — Verification checklist

Mark each item before declaring the repo enrolled:

- [ ] Confirmed no prconverged enrollment conflict (Step 1)
- [ ] All five org secrets accessible to this repo (Step 2a)
- [ ] `developer-bot` and `reviewer-bot` apps installed on this repo (Step 2b)
- [ ] `agent-loop.yml` committed to `main` (Step 3)
- [ ] Branch protection requires `reviewer-agent-passed` on `main` (Step 4)
- [ ] `CODEOWNERS` covers secrets, release pipelines, infra, and auth paths (Step 5)
- [ ] All `agent:*` labels created (Step 6)
- [ ] Positive smoke test passed: issue → PR → reviewed → merged autonomously (Step 7)
- [ ] Negative smoke test passed: `reviewer-agent-passed` absence blocks merge (Step 7)

---

## Kill switches

### `agent:pause`

Add the `agent:pause` label to any PR or issue to immediately halt autonomous processing. No new developer or reviewer runs will start. Runs already in progress are not cancelled.

Remove the label to re-enable automation.

### `agent:needs-human`

Applied automatically by the developer workflow when the attempt cap is reached (default: 3 attempts). Once applied, no further developer or reviewer runs start. A human must review the PR manually.

To reset: remove `agent:needs-human` and all `agent:attempt-*` labels from the PR.

---

## Failure runbook

See [`failure-runbook.md`](failure-runbook.md) for diagnosis and recovery steps covering:
- Reviewer stuck in a loop
- Attempt cap hit
- `reviewer-agent-passed` check blocked (runner outage, Anthropic outage)
- `riddim-release` `main` broken (blast radius: all consumers)
- Manual override path for `reviewer-agent-passed` failure

---

## Related resources

- [`e1-checklist.md`](e1-checklist.md) — org-level prerequisites (do this before enrolling any repo)
- [`failure-runbook.md`](failure-runbook.md) — diagnosis and recovery
- [`trigger-wrapper-template.yml`](trigger-wrapper-template.yml) — canonical wrapper template
- [`scripts/enroll-repo.sh`](../../scripts/enroll-repo.sh) — per-repo enrollment automation
- [RIDDIM-91](https://riddim.atlassian.net/browse/RIDDIM-91) — parent initiative
- [RIDDIM-99](https://riddim.atlassian.net/browse/RIDDIM-99) — this epic
