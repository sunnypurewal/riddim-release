# Autonomous PR Loop - Onboarding Guide

> Last verified against `riddim-release@1a45148` on `2026-04-30`.
> Update this header whenever a material workflow change lands in riddim-release.

**Goal:** enroll a new consumer repo in the autonomous PR loop in under 30 minutes.

Trigger surface is the Jira `agent:pr` label -> `repository_dispatch: jira-ticket-ready` -> `developer-bot` opens PR. GitHub Issues are not used.

---

## Overview

The autonomous PR loop handles the developer -> review -> merge cycle for routine changes. The reusable workflows live in `RiddimSoftware/riddim-release`, and each consumer repo adds one thin wrapper at `.github/workflows/agent-loop.yml`.

Actors:

1. `riddim-developer-bot` opens implementation PRs from an already-pushed branch.
2. `riddim-reviewer-bot` reviews developer-bot PRs and requests fix-ups or approves.
3. GitHub auto-merge squashes the PR after branch protection passes.
4. `rebase-watcher.yml` detects stale autonomous PRs and routes clean rebases or conflict escalation.

The Jira ticket remains the source of truth. Adding Jira label `agent:pr` is the entry point.

---

## Step 1 - Confirm this loop owns the repo

Before enrolling, confirm the target repo is not simultaneously enrolled in any older local or daemon-based merge pipeline.

Checklist:

- Search the consumer repo for old autonomous workflow files.
- Confirm branch protection will require `reviewer-agent-passed`.
- Confirm the consumer project has, or will receive, a Jira Automation rule for `agent:pr`.
- Note any removed legacy automation in the enrollment PR.

Both pipelines must not run at once. Double enrollment can produce duplicate PRs, duplicate reviews, or competing auto-merge attempts.

---

## Step 2 - Grant org secrets and bot-app access

The consumer repo must have selected-repository access to the shared org secrets and both GitHub Apps.

### Step 2a - Org secrets

Required secrets:

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` against the Max-plan OAuth token. |
| `DEV_BOT_APP_ID` | GitHub App ID for the developer bot. |
| `DEV_BOT_PRIVATE_KEY` | Private key used to mint short-lived developer-bot installation tokens. |
| `REVIEWER_BOT_APP_ID` | GitHub App ID for the reviewer bot. |
| `REVIEWER_BOT_PRIVATE_KEY` | Private key used to mint short-lived reviewer-bot installation tokens. |
| `DEV_BOT_PAT` | Fine-grained PAT consumed only by `rebase-watcher.yml`; scope to one consumer repo with Contents read/write and rotate within 90 days. |

`REVIEWER_BOT_PAT` is not required by the current developer/reviewer/create-pr/rebase flow.

A GitHub org admin grants access at:

`https://github.com/organizations/RiddimSoftware/settings/secrets/actions`

Fine-grained PAT org policy must also allow PATs for RiddimSoftware resources:

`https://github.com/organizations/RiddimSoftware/settings/personal-access-tokens`

Without that policy, `RiddimSoftware` will not appear as a resource owner when minting the PAT.

Verify the PAT can see the consumer repo:

```bash
curl -fsSI \
  -H "Authorization: Bearer $PAT" \
  https://api.github.com/repos/RiddimSoftware/<consumer>
```

A successful setup returns HTTP 200.

### Step 2b - GitHub App installation

Confirm both Apps are installed for the consumer repo:

- `riddim-developer-bot`
- `riddim-reviewer-bot`

Repository access should be selected-repository access, not all-repository access unless that is an explicit org decision.

Required App permissions:

- Contents: read/write
- Pull requests: read/write
- Issues: read/write
- Workflows: read/write
- Metadata: read

---

## Step 3 - Add the trigger wrapper workflow

Copy `docs/agent-loop/trigger-wrapper-template.yml` into the consumer repo at `.github/workflows/agent-loop.yml`.

The template mirrors the live `epac` wrapper shape:

- `repository_dispatch` type `jira-ticket-ready`
- `pull_request` for developer-bot PR open/sync/ready events
- `pull_request_review` for reviewer-bot changes-requested fix-ups
- `push` to `main` for stale-PR detection
- 15-minute `schedule` backstop for stale-PR detection
- `workflow_dispatch` for manual rebase-watcher smoke checks

Canonical job map:

| Job | Trigger | Reusable workflow |
|---|---|---|
| `create-pr-from-jira` | `repository_dispatch: jira-ticket-ready` | `RiddimSoftware/riddim-release/.github/workflows/create-pr.yml@main` |
| `developer-fixup` | reviewer-bot requested changes | `RiddimSoftware/riddim-release/.github/workflows/developer.yml@main` |
| `reviewer` | developer-bot PR opened/synchronized/ready | `RiddimSoftware/riddim-release/.github/workflows/reviewer.yml@main` |
| `rebase-watcher` | `push`, `schedule`, or `workflow_dispatch` | `RiddimSoftware/riddim-release/.github/workflows/rebase-watcher.yml@main` |

The Jira dispatch payload supplies these fields to `create-pr.yml`:

```yaml
with:
  jira_ticket: ${{ github.event.client_payload.jira_ticket }}
  jira_summary: ${{ github.event.client_payload.jira_summary }}
  branch: ${{ github.event.client_payload.branch || '' }}
  jira_url: ${{ github.event.client_payload.jira_url || '' }}
```

The `branch` field is optional. If omitted, `create-pr.yml` resolves a pushed branch by finding a ref name containing the Jira ticket key, case-insensitively.

Do not document `gh pr create` as a fallback. Human-authored PRs do not satisfy the two-identity contract for autonomous review and merge.

---

## Step 4 - Configure branch protection on `main`

Branch protection must block merge until the reviewer gate and repo-local checks pass.

Required settings:

| Setting | Value |
|---|---|
| Require a pull request before merging | Enabled |
| Required approving reviews | 1 |
| Dismiss stale pull request approvals when new commits are pushed | Enabled |
| Require review from Code Owners | Enabled for high-risk paths |
| Require conversation resolution before merging | Enabled |
| Require status checks to pass before merging | Enabled |
| Required status check | `reviewer-agent-passed` |
| Require branches to be up to date before merging | Enabled |
| Allow auto-merge | Enabled |
| Automatically delete head branches | Enabled |

Preserve existing consumer CI checks. Add `reviewer-agent-passed`; do not replace the current check list.

---

## Step 5 - Author CODEOWNERS for high-risk paths

Create or update `<consumer-repo>/CODEOWNERS` so sensitive files require a human owner even when the reviewer bot approves the rest of the PR.

Minimum categories:

- Secrets and credentials: `.env*`, `**/.env*`, secret material, credential material.
- GitHub Actions and automation: `.github/`, `.github/workflows/`.
- Release pipelines: `fastlane/`, deployment scripts, app-store or production release configuration.
- Platform-specific production surfaces such as iOS signing, Android signing, Terraform, or infrastructure code.

Use the consumer repo's real owner handle or team slug. Do not copy `epac` owners blindly.

---

## Step 6 - Create required labels

Create only the labels consumed by the wrapper or guard workflows:

| Label | Purpose |
|---|---|
| `autonomous` | Marks PRs enrolled in the autonomous review/merge loop; added by `create-pr.yml`. |
| `agent:pause` | Kill switch that suppresses developer/reviewer automation. |
| `agent:needs-human` | Marks work that exceeded guardrails or requires manual review. |
| `agent:attempt-1` | Developer fix-up attempt counter. |
| `agent:attempt-2` | Developer fix-up attempt counter. |
| `agent:attempt-3` | Developer fix-up attempt counter. |
| `agent:rebase-attempt-1` | Rebase attempt counter. |
| `agent:rebase-attempt-2` | Rebase attempt counter. |
| `agent:rebase-attempt-3` | Rebase attempt counter. |
| `agent:rebase-failed` | Rebase attempts exhausted or conflict guard failed. |
| `automate` | Enables GitHub auto-merge policy where the repo uses this marker. |

The Jira label `agent:pr` lives on the Jira ticket. It does not need to be a GitHub repo label.

---

## Step 7 - Add the Jira Automation rule

Add this rule in the consumer's Jira project.

Trigger:

- Field value changed
- Field: `Labels`
- Change type: `Added`
- Label: `agent:pr`

Action:

- Send web request
- URL: `https://api.github.com/repos/RiddimSoftware/<consumer>/dispatches`
- Method: `POST`
- Wait for response: yes

Headers:

```text
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json
Authorization: Bearer <PAT>
```

Store the PAT in Atlassian Automation rule variables or secret storage. Never paste a literal token into the rule body or a Jira comment.

Body:

```json
{
  "event_type": "jira-ticket-ready",
  "client_payload": {
    "jira_ticket": "{{issue.key}}",
    "jira_summary": "{{issue.summary.jsonEncode}}",
    "jira_url": "{{issue.url}}"
  }
}
```

Omit `branch` by default so `create-pr.yml` resolves by ticket-key substring. Include it only when the branch name cannot include the ticket key.

PAT requirements:

- Fine-grained PAT
- Resource owner: `RiddimSoftware`
- Selected repository: exactly one consumer repo
- Permission: Contents read/write
- Expiry: 90 days or less

---

## Step 8 - Smoke test the dispatch flow

Use a low-risk throwaway ticket.

1. Push a throwaway branch named `claude/<ticket-key-lower>-noop` containing one trivial commit.
2. Create a Jira ticket in the consumer project with summary `noop test` and one clear acceptance criterion.
3. Add Jira label `agent:pr` to the ticket.
4. Within about 30 seconds, expect a successful Jira Automation audit-log entry.
5. Confirm a GitHub Actions run starts on `Autonomous PR Loop` from `repository_dispatch`.
6. Confirm a PR opens by `riddim-developer-bot[bot]` with title `<TICKET>: noop test`.
7. Confirm the PR receives the `autonomous` label.
8. Confirm auto-merge is enabled with squash strategy.

Negative smoke test:

- Open or identify a test PR without `reviewer-agent-passed`.
- Confirm branch protection blocks merge.
- Do not relax branch protection except as a documented manual override from `failure-runbook.md`.

---

## Step 9 - Verification checklist

Enrollment is complete when all checks pass:

- Consumer wrapper contains `repository_dispatch: jira-ticket-ready`.
- Consumer wrapper has no GitHub-Issues entry point.
- Jira Automation rule fires when Jira label `agent:pr` is added.
- Jira Automation request body includes `jira_ticket`, `jira_summary`, and `jira_url`.
- `create-pr-from-jira` calls `create-pr.yml@main`.
- `developer-fixup` calls `developer.yml@main` only after reviewer-bot changes requested.
- `reviewer` calls `reviewer.yml@main` only for developer-bot PRs.
- `rebase-watcher` calls `rebase-watcher.yml@main` on `push`, `schedule`, or `workflow_dispatch`.
- `reviewer-agent-passed` is required on `main`.
- CODEOWNERS covers high-risk paths.
- Required labels exist in GitHub.
- Jira label `agent:pr` has opened a smoke-test PR through `repository_dispatch`.
