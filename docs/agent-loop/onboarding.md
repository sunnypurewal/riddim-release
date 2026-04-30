# Autonomous PR Loop — Onboarding Guide

> Last verified against `riddim-release@4834891` on `2026-04-30`.
> Update this header whenever a material workflow change lands in riddim-release.

**Goal:** enroll a new consumer repo in the autonomous PR loop in < 30 minutes.

**Trigger surface:** Jira `agent:pr` label -> `repository_dispatch: jira-ticket-ready` -> `developer-bot` opens PR. GitHub Issues are not used.

---

## Overview

The autonomous PR loop handles the developer -> review -> merge cycle for routine changes after a branch has already been pushed for the Jira ticket. Four moving parts collaborate:

1. **Jira Automation** watches for the Jira label `agent:pr` and sends `repository_dispatch` with the ticket key, summary, optional branch, and Jira URL.
2. **Developer bot** (`riddim-developer-bot`) runs `create-pr.yml`, resolves a pushed branch containing the Jira ticket key when no branch is supplied, opens the PR, applies `autonomous`, and enables squash auto-merge.
3. **Reviewer bot** (`riddim-reviewer-bot`) reviews developer-bot PRs through `reviewer.yml` and either approves with the `reviewer-agent-passed` check or requests changes.
4. **Rebase watcher** (`rebase-watcher.yml`) scans open `autonomous` PRs on base-branch pushes and a cron backstop, then routes stale PRs to rebase recovery.

The reusable workflows live in `RiddimSoftware/riddim-release` and are called from a thin trigger wrapper in each consumer repo.

---

## Step 1 — Confirm this loop owns the repo (not prconverged)

Before enrolling, confirm that the target repo is leaving the `prconverged` pipeline and moving to the RIDDIM-91 autonomous loop.

```bash
# Is the repo currently using prconverged?
gh api repos/<owner>/<repo>/contents/.github/workflows \
  --jq '.[].name' | grep -i prconverged

# Check org-level prconverged config (if applicable)
gh api orgs/RiddimSoftware/actions/secrets --jq '.secrets[].name' | grep -i prconverged
```

Allocation rules:

- A repo must use either prconverged or the RIDDIM-91 loop, not both.
- If prconverged is present, remove or disable it before enrolling.
- Note in the ticket/PR that prconverged was removed and by whom.

---

## Step 2 — Grant org-secrets and bot-app access

The consumer repo must be granted access to the org-level secrets and have the GitHub Apps installed.

### 2a — Org secrets

Verify that these org secrets are accessible to the new repo from **Settings -> Secrets and variables -> Actions -> Organization secrets**:

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates `claude-code-action` for developer/reviewer agents. |
| `DEV_BOT_APP_ID` | Developer-bot GitHub App ID used by `create-pr.yml` and `developer.yml`. |
| `DEV_BOT_PRIVATE_KEY` | Developer-bot GitHub App private key used to mint installation tokens. |
| `REVIEWER_BOT_APP_ID` | Reviewer-bot GitHub App ID used by `reviewer.yml`. |
| `REVIEWER_BOT_PRIVATE_KEY` | Reviewer-bot GitHub App private key used to mint installation tokens. |
| `DEV_BOT_PAT` | Rebase-watcher only. Fine-grained PAT or equivalent token with `contents:read/write`, `pull_requests:write`, and `actions:write` on the consumer repo. Use <=90 day expiry. |

`REVIEWER_BOT_PAT` is not required for the current developer/reviewer/create-pr path.

```bash
# Check which org secrets the repo can currently access:
gh api repos/<owner>/<repo>/actions/organization-secrets --jq '[.secrets[].name]'
```

If any are missing, a GitHub org admin must grant repository access at:
`https://github.com/organizations/RiddimSoftware/settings/secrets/actions`

To avoid replacing existing repository grants, add each repo with the per-repo endpoint:

```bash
CONSUMER="RiddimSoftware/your-repo"
CONSUMER_ID="$(gh api /repos/${CONSUMER} --jq .id)"

for SECRET in \
  CLAUDE_CODE_OAUTH_TOKEN \
  DEV_BOT_APP_ID DEV_BOT_PRIVATE_KEY \
  REVIEWER_BOT_APP_ID REVIEWER_BOT_PRIVATE_KEY \
  DEV_BOT_PAT; do
  gh api \
    --method PUT \
    "/orgs/RiddimSoftware/actions/secrets/${SECRET}/repositories/${CONSUMER_ID}"
done
```

### 2b — GitHub App installation

Confirm `developer-bot` and `reviewer-bot` are installed at org scope with access to the new repo:

```bash
gh api orgs/RiddimSoftware/installations --jq '.installations[].app_slug'

gh api "app/installations/<installation_id>/repositories" \
  --jq '.repositories[].full_name' | grep <repo-name>
```

If either app is not installed on the repo, go to:
`https://github.com/organizations/RiddimSoftware/settings/installations`
-> find each bot -> **Configure** -> add the new repo.

---

## Step 3 — Add the trigger wrapper workflow

Copy the canonical trigger wrapper into the consumer repo:

```bash
# From the riddim-release repo root:
gh api repos/RiddimSoftware/riddim-release/contents/docs/agent-loop/trigger-wrapper-template.yml \
  --jq '.content' | base64 -d > /tmp/agent-loop.yml

cp /tmp/agent-loop.yml <path-to-consumer-repo>/.github/workflows/agent-loop.yml
```

The wrapper must include these triggers:

- `repository_dispatch` with `types: [jira-ticket-ready]`
- `pull_request` with `opened`, `synchronize`, and `ready_for_review`
- `pull_request_review` with `submitted`
- `push` on `main`
- `schedule` every 15 minutes
- `workflow_dispatch`

The wrapper must include these jobs:

- `create-pr-from-jira` calls `RiddimSoftware/riddim-release/.github/workflows/create-pr.yml@main` with `client_payload.jira_ticket`, `jira_summary`, `branch`, and `jira_url`.
- `developer-fixup` calls `developer.yml` when `riddim-reviewer-bot` requests changes.
- `reviewer` calls `reviewer.yml` when `riddim-developer-bot` opens or updates a PR.
- `rebase-watcher` calls `rebase-watcher.yml` on `push`, `schedule`, and `workflow_dispatch`.

Use [`trigger-wrapper-template.yml`](trigger-wrapper-template.yml) as the single source of truth. Commit `agent-loop.yml` to `main` of the consumer repo before continuing.

---

## Step 4 — Configure branch protection on `main`

Branch protection must require `reviewer-agent-passed` so PRs cannot merge without the reviewer completing its check.

```bash
# From the riddim-release root:
bash scripts/enroll-repo.sh <owner/repo>
```

The script prints the branch settings URL. Apply these settings manually on the `main` branch rule:

| Setting | Value |
|---|---|
| Require a pull request before merging | Yes |
| Required approving reviews | 1 |
| Dismiss stale reviews on new pushes | Yes |
| Require status checks to pass before merging | Yes |
| Required status check name | `reviewer-agent-passed` |
| Require branches to be up to date before merging | Yes |
| Allow auto-merge | Yes |
| Automatically delete head branches | Yes |

`reviewer-agent-passed` is the critical gate. Without it, PRs can merge before the reviewer finishes. With it, a runner or Anthropic outage blocks all merges; see `failure-runbook.md` for the manual override procedure.

---

## Step 5 — Author CODEOWNERS for high-risk paths

Create `<consumer-repo>/CODEOWNERS` covering paths that should require a human approver even when the reviewer bot approves the rest of the PR.

Checklist of high-risk path categories to cover:

- [ ] Secrets and credentials: `.env*`, `**/.env*`, `**/*secret*`, `**/*credential*`
- [ ] Release pipelines: `fastlane/`, `.github/workflows/`, `Makefile`, `scripts/release*`
- [ ] Infrastructure and cloud config: `terraform/`, `infra/`, `k8s/`, `docker-compose*`
- [ ] Authentication: `**/auth/`, `**/authentication/`, `**/*Auth*`

Minimum recommended `CODEOWNERS`:

```text
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

Adjust paths to match the repo's actual directory structure.

---

## Step 6 — Create the required label set

These PR labels must exist on the consumer repo. `autonomous` is added by `create-pr.yml`; the other labels are consumed by wrappers or guards.

| Label | Purpose |
|---|---|
| `autonomous` | Added by `create-pr.yml`; enrolls the PR in review/rebase automation. |
| `automate` | Compatibility label for automation follow-up and manual handoffs. |
| `agent:pause` | Halts autonomous workflows on a PR. |
| `agent:needs-human` | Applied when a guard or attempt cap blocks automation. |
| `agent:attempt-1` | First developer fix-up attempt. |
| `agent:attempt-2` | Second developer fix-up attempt. |
| `agent:attempt-3` | Third/default final developer fix-up attempt. |
| `agent:rebase-attempt-1` | First stale-PR rebase attempt. |
| `agent:rebase-attempt-2` | Second stale-PR rebase attempt. |
| `agent:rebase-attempt-3` | Third/default final stale-PR rebase attempt. |
| `agent:rebase-failed` | Marks PRs where rebase recovery failed or exhausted its cap. |

---

## Step 7 — Configure the Jira Automation rule

Create this rule in the consumer's Jira project. This is a manual web-UI step; Atlassian Automation is not managed as code here.

### Trigger

- Trigger: **Field value changed**
- Field: `Labels`
- Change type: `Added`
- Label: `agent:pr`

### Action: send web request

- URL: `https://api.github.com/repos/RiddimSoftware/<consumer>/dispatches`
- Method: `POST`
- Wait for response: `Yes`
- Headers:
  - `Accept: application/vnd.github+json`
  - `X-GitHub-Api-Version: 2022-11-28`
  - `Content-Type: application/json`
  - `Authorization: Bearer <PAT>`

Body:

```json
{
  "event_type": "jira-ticket-ready",
  "client_payload": {
    "jira_ticket": "{{issue.key}}",
    "jira_summary": "{{issue.summary}}",
    "jira_url": "{{issue.url}}"
  }
}
```

Omit `branch` by default. `create-pr.yml` resolves the first pushed branch whose name contains the Jira ticket key, case-insensitive.

### PAT requirements

- Fine-grained PAT
- Resource owner: `RiddimSoftware`
- Selected repository: the single consumer repo
- Repository permission: `Contents: Read and write`
- Expiry: <=90 days
- Storage: Atlassian Automation secret or rule variable, never inline in the JSON body

Org policy precondition: fine-grained PATs against org resources require the org policy to allow them. Check `https://github.com/organizations/RiddimSoftware/settings/personal-access-tokens` if `RiddimSoftware` does not appear as a PAT resource owner.

Verify PAT access before saving the rule:

```bash
curl -fsSI \
  -H "Authorization: Bearer $PAT" \
  https://api.github.com/repos/RiddimSoftware/<consumer>
```

Expect HTTP 200.

---

## Step 8 — Run the dispatch smoke test

With enrollment complete, run both a positive and a negative smoke test before treating the repo as production-enrolled.

### Positive smoke test

1. Push a throwaway branch named `claude/<ticket-key-lower>-noop` containing one trivial commit.
2. Create a Jira ticket in the consumer's project with summary `noop test` and one simple acceptance criterion.
3. Add the Jira label `agent:pr` to the ticket.
4. Within ~30 seconds, expect the Jira Automation audit log to show a successful web request.
5. Confirm the consumer repo's `Autonomous PR Loop` workflow starts from `repository_dispatch`.
6. Confirm a PR opens by `riddim-developer-bot[bot]` titled `<TICKET>: noop test`.
7. Confirm the `autonomous` label is applied and squash auto-merge is enabled.

Positive smoke test passes when Jira label -> dispatch -> PR opened by developer-bot -> reviewer-bot reviews -> PR auto-merges after required checks.

### Negative smoke test

Confirm that the `reviewer-agent-passed` branch protection gate blocks merges when the check is absent.

1. Temporarily remove `reviewer-agent-passed` from required status checks on `main`.
2. Open a draft PR from any branch. Confirm the merge button is not blocked by that status check.
3. Re-add `reviewer-agent-passed` as a required check.
4. Open a new PR. Before the reviewer runs, confirm the merge button shows that required checks have not run yet.
5. Let the reviewer run to completion and confirm the PR becomes mergeable.

Negative smoke test passes when `reviewer-agent-passed` absence visibly blocks the merge button.

---

## Step 9 — Verification checklist

Mark each item before declaring the repo enrolled:

- [ ] Confirmed no prconverged enrollment conflict.
- [ ] Required org secrets accessible to this repo.
- [ ] `developer-bot` and `reviewer-bot` apps installed on this repo.
- [ ] `agent-loop.yml` committed to `main` from the current template.
- [ ] Branch protection requires `reviewer-agent-passed` on `main`.
- [ ] `CODEOWNERS` covers secrets, release pipelines, infra, and auth paths.
- [ ] Required PR labels exist for the dispatch-based flow.
- [ ] Jira Automation rule sends `repository_dispatch:jira-ticket-ready` when `agent:pr` is added.
- [ ] Positive smoke test passed: Jira label -> dispatch -> PR -> reviewed -> merged autonomously.
- [ ] Negative smoke test passed: `reviewer-agent-passed` absence blocks merge.

---

## Kill switches

### `agent:pause`

Add the `agent:pause` label to any PR to halt autonomous processing. No new developer, reviewer, or rebase runs should start for that PR. Remove the label to re-enable automation.

### `agent:needs-human`

Applied automatically when the attempt cap or a guard blocks automation. Once applied, no further developer or reviewer runs start for that PR. A human must review manually or reset the labels.

---

## Failure runbook

See [`failure-runbook.md`](failure-runbook.md) for diagnosis and recovery steps covering reviewer loops, attempt caps, `reviewer-agent-passed` outages, broken `riddim-release@main`, and manual override paths.

---

## Configuration

### Rebase guard thresholds (E10)

The rebase guard enforces three safety limits on automated rebases. All three have defaults that can be overridden per consumer repo via workflow inputs.

| Variable | Default | Override via |
|---|---|---|
| `REBASE_MAX_ATTEMPTS` | `3` | `rebase_max_attempts` workflow input. |
| `REBASE_MAX_FILES` | `8` | `rebase_max_files` workflow input. |
| `REBASE_MAX_LINES` | `200` | `rebase_max_lines` workflow input. |

For full details, see [`e10-rebase-guards.md`](e10-rebase-guards.md).

---

## Related resources

- [`e1-checklist.md`](e1-checklist.md) — org-level prerequisites.
- [`failure-runbook.md`](failure-runbook.md) — diagnosis and recovery.
- [`trigger-wrapper-template.yml`](trigger-wrapper-template.yml) — canonical wrapper template.
- [`e10-rebase-guards.md`](e10-rebase-guards.md) — rebase guard thresholds, attempt counter, CODEOWNERS veto.
- [`scripts/enroll-consumer.sh`](../../scripts/enroll-consumer.sh) — per-repo enrollment automation.
- [`scripts/enroll-repo.sh`](../../scripts/enroll-repo.sh) — legacy enrollment helper.
- [RIDDIM-91](https://riddim.atlassian.net/browse/RIDDIM-91) — parent initiative.
- [RIDDIM-99](https://riddim.atlassian.net/browse/RIDDIM-99) — onboarding epic.
