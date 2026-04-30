# Autonomous PR Loop — Failure Runbook

> Last verified against riddim-release@main on 2026-04-30.
> Update this header whenever a material workflow change lands in riddim-release.

Quick reference for diagnosing and recovering from failures in the autonomous PR loop. Each section states the symptom, diagnosis steps, and recovery action.

Trigger surface: Jira label `agent:pr` -> GitHub `repository_dispatch` type `jira-ticket-ready` -> `create-pr.yml` opens the PR as `riddim-developer-bot`. GitHub Issues are not used as the entry point.

---

## 1. Reviewer stuck in a loop

**Symptom:** The reviewer workflow keeps running, requesting changes, and then the developer fixes up, but the cycle does not converge after 2–3 rounds.

**Diagnosis:**
```bash
# Check current attempt labels on the PR
gh pr view <pr-number> --repo <owner/repo> --json labels --jq '.labels[].name'

# Check reviewer run logs
gh run list --repo <owner/repo> --workflow agent-loop.yml --limit 10
gh run view <run-id> --repo <owner/repo> --log
```

**Recovery:**
1. Add `agent:pause` label to the PR to stop the loop immediately:
   ```bash
   gh pr edit <pr-number> --repo <owner/repo> --add-label "agent:pause"
   ```
2. Read the reviewer's latest comment to understand the sticking point.
3. Either manually push a fix to the PR branch, or close the PR and refile the issue with clearer acceptance criteria.
4. Remove `agent:pause` (and if needed, all `agent:attempt-*` labels and `agent:needs-human`) to re-enable the loop:
   ```bash
   gh pr edit <pr-number> --repo <owner/repo> --remove-label "agent:pause"
   ```

---

## 2. Attempt cap hit (`agent:needs-human`)

**Symptom:** The PR has the `agent:needs-human` label. No new developer or reviewer runs start.

**Diagnosis:**
The developer workflow applies `agent:needs-human` after exhausting the attempt counter (`agent:attempt-1` through `agent:attempt-3`). The PR is intentionally frozen for human review.

```bash
gh pr view <pr-number> --repo <owner/repo> --json labels,url
```

**Recovery — human reviews manually:**
1. Read the PR diff and the reviewer bot's comments.
2. Either approve and merge manually, or close the PR.
3. If you want to reset the loop and let automation retry:
   ```bash
   gh pr edit <pr-number> --repo <owner/repo> \
     --remove-label "agent:needs-human" \
     --remove-label "agent:attempt-1" \
     --remove-label "agent:attempt-2" \
     --remove-label "agent:attempt-3"
   ```
   Then push a fix commit to the branch to trigger the reviewer again, or close the PR and re-run the Jira `agent:pr` dispatch flow from a fresh branch.

---

## 3. `reviewer-agent-passed` check blocked (runner outage or reviewer regression)

**Symptom:** PRs are open and valid, but the `reviewer-agent-passed` required status check is stuck in `pending` or `queued`. The reviewer workflow is not completing.

**Diagnosis:**
```bash
# Check recent reviewer runs
gh run list --repo <owner/repo> --workflow agent-loop.yml --limit 5

# Check GitHub Actions status at the org level
gh api /repos/RiddimSoftware/riddim-release/actions/runs --jq '.workflow_runs[:3] | .[] | {status, conclusion, created_at, head_commit: .head_commit.message}'
```

Common causes:
- GitHub Actions runner outage (check https://www.githubstatus.com)
- Anthropic API outage affecting `CLAUDE_CODE_OAUTH_TOKEN`
- A regression committed to `riddim-release/main` (see section 4)

**Manual override path — use only when safe:**

Override is safe when ALL of the following are true:
- You have read the PR diff yourself and it is correct
- The failure is confirmed to be infrastructure (runner/API outage), not a code quality issue
- The PR was previously passing reviewer checks before the outage

Steps:
1. Disable auto-merge to prevent an accidental merge while you work:
   ```bash
   gh pr merge <pr-number> --repo <owner/repo> --disable-auto
   ```
2. Approve the PR manually from your own account:
   ```bash
   gh pr review <pr-number> --repo <owner/repo> --approve --body "Manual override: runner outage confirmed, diff reviewed manually."
   ```
3. If branch protection blocks merge due to missing `reviewer-agent-passed`, a repo admin must temporarily remove it from required checks in Settings → Branches, merge, then restore the rule.
4. Document the override in a PR comment with: date, reason, who approved, and that `reviewer-agent-passed` was bypassed.

**Do not override** if you are uncertain whether the reviewer would have approved. When in doubt, wait for the outage to resolve.

---

## 4. riddim-release `main` is broken (blast radius: all consumers)

**Symptom:** All consumer repos' developer and reviewer workflows fail simultaneously. The `uses:` reference pins to `@main`, so a bad commit to riddim-release breaks every consumer.

**Diagnosis:**
```bash
# Find the breaking commit
git -C /path/to/riddim-release log --oneline -10

# Check a recent failed consumer run for the error
gh run view <run-id> --repo <consumer-owner/consumer-repo> --log | grep -i error
```

**Recovery:**
1. Identify the breaking commit in `riddim-release`.
2. Revert it:
   ```bash
   cd /path/to/riddim-release
   git revert <sha> --no-edit
   git push origin main
   ```
3. Communicate to consumer repo maintainers that a regression was introduced and reverted (post in the relevant Slack channel or as a PR comment on any stuck PRs).
4. Re-trigger stuck consumer workflows by re-syncing the PR branch:
   ```bash
   gh api repos/<owner/repo>/actions/runs/<run-id>/rerun --method POST
   ```
   Or push an empty commit to the PR branch to re-trigger the reviewer.

---

## Reading `agent:attempt-N` labels

The attempt counter increments each time the developer workflow starts a fix-up pass. Labels are additive — a PR at attempt 3 will have all three labels present.

| Labels present | State |
|---|---|
| `agent:attempt-1` only | First fix-up in progress or complete |
| `agent:attempt-1` + `agent:attempt-2` | Second fix-up in progress or complete |
| All three + `agent:needs-human` | Cap hit, frozen for human review |

To check programmatically:
```bash
gh pr view <pr-number> --repo <owner/repo> --json labels --jq '[.labels[].name | select(startswith("agent:attempt"))] | length'
```

---

## Quick-reference commands

```bash
# Pause a PR
gh pr edit <pr-number> --repo <owner/repo> --add-label "agent:pause"

# Resume a PR
gh pr edit <pr-number> --repo <owner/repo> --remove-label "agent:pause"

# Disable auto-merge
gh pr merge <pr-number> --repo <owner/repo> --disable-auto

# View workflow run logs
gh run view <run-id> --repo <owner/repo> --log

# Re-run a failed workflow
gh run rerun <run-id> --repo <owner/repo>
```

---

## 5. Stale PR rebase guard stopped automation

**Symptom:** A PR has `agent:needs-human`, possibly with `agent:rebase-attempt-3` or `agent:codeowners-veto`, and a PR comment beginning with `<!-- riddim:rebase-guard:* -->`.

**Diagnosis:**
```bash
gh pr view <pr-number> --repo <owner/repo> --json labels
gh pr view <pr-number> --repo <owner/repo> --comments
```

Common guard decisions:

| Decision | Meaning |
|---|---|
| `attempt-cap-exceeded` | The PR reached the configured stale-PR rebase cap, default 3 |
| `size-cap-exceeded` | Conflict surface exceeded `REBASE_MAX_FILES` or `REBASE_MAX_LINES` |
| `codeowners-veto` | A conflicted file is owned by a human/team in CODEOWNERS |

**Recovery:**
1. Add `agent:pause` while inspecting if it is not already present.
2. Rebase locally and resolve conflicts manually.
3. Push the resolved branch.
4. Remove `agent:needs-human`, `agent:pause`, and any `agent:rebase-attempt-*` labels only after the branch is safe to return to automation.

---

## 6. Common failure modes from E6 pilot

These failure modes were confirmed in the E6 pilot on `RiddimSoftware/epac`. Each one looks alarming but has a known, non-destructive resolution.

### `startup_failure` on reviewer job for human-opened PRs

**Symptom:** The reviewer workflow shows `startup_failure` or exits immediately for PRs opened by a human account.

**Cause:** This is expected. The reviewer job has an `if:` condition that checks `github.event.pull_request.user.login == 'developer-bot'`. PRs not opened by the developer bot intentionally do not trigger the reviewer workflow.

**Action:** None. The condition is correct. If you see this on a developer-bot PR, check that the bot's GitHub login matches exactly.

---

### GitHub Issues disabled — `agent:build` label trigger never fires

**Symptom:** You add the `agent:build` label to an issue, but no workflow run starts.

**Cause:** The `issues: labeled` GitHub event only fires when the Issues feature is enabled in the repository settings. If Issues are disabled, the event is suppressed entirely — the workflow never sees the label.

**Recovery:**
1. Go to: `https://github.com/<owner>/<repo>/settings`
2. Under **Features**, check **Issues**.
3. Re-add the `agent:build` label to the issue (the event already missed it).

**Prevention:** The `enroll-consumer.sh` script prints this as a required manual step.

---

### `agent-loop.yml` not merged — workflows not active

**Symptom:** No workflows run on any label or PR event, even with Issues enabled.

**Cause:** The trigger wrapper `.github/workflows/agent-loop.yml` was not committed to the consumer repo's `main` branch (or was committed to a branch that is not yet merged).

**Recovery:** Commit `agent-loop.yml` to `main`. Use `enroll-consumer.sh` which does this automatically.

---

### Cross-org reusable workflow access denied

**Symptom:** Workflow run fails with: `workflow was not found` or `access denied` when calling `RiddimSoftware/riddim-release/.github/workflows/developer.yml@main`.

**Cause:** The GitHub organization policy may restrict reusable workflow calls to workflows within the same org, or specifically require allowlisting.

**Recovery:**
1. Go to: `https://github.com/organizations/RiddimSoftware/settings/actions`
2. Under **Policies**, find the setting for cross-organization workflow access.
3. Select **Allow workflows from all organizations** or add `RiddimSoftware/riddim-release` to the allowlist.
4. Re-run the failed workflow.

---

## 7. Prompt drift

**What it is:** The conflict-resolver Claude prompt is versioned (e.g. `conflict-resolver-v1.md`). Over time, prompt updates may change resolution behaviour in ways that break existing consumers.

**How to update:**
1. Create the new prompt file: `docs/prompts/conflict-resolver-v2.md` in `riddim-release`.
2. Update `agent-rebase.yml` to reference `v2` instead of `v1`.
3. Test on `riddim-release` itself before merging to `main`.
4. After merging, all consumers automatically pick up `v2` via their `@main` pin.
5. Document the change in a PR comment and update the verified header on this runbook.

**Why this matters:** All consumers pin to `@main` in `riddim-release`. A single prompt commit affects every repo simultaneously. Test on a low-stakes repo before merging prompt changes to `main`.
