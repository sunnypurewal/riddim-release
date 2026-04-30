# Autonomous PR Loop — Failure Runbook

> **Last verified against `riddim-release@4eb3b6e` on 2026-04-30.**
> Update this header whenever a material workflow change lands in riddim-release.

Quick reference for diagnosing and recovering from failures in the autonomous PR loop. Each section states the symptom, diagnosis steps, and recovery action.

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
   Then push a fix commit to the branch to trigger the reviewer again, or re-add `agent:build` to the source issue to start fresh.

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
