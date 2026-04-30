# Autonomous PR Loop — Failure Runbook

> **Last verified against `riddim-release@19898ca` on 2026-04-30.**  
> Update this header whenever a material workflow change lands in riddim-release.

Quick reference for diagnosing and recovering from failures in the autonomous PR loop. Each section states the symptom, diagnosis steps, and recovery action.

For first-time setup, see [onboarding.md](./onboarding.md) first.

---

## 1. Reading PR state

Before taking any recovery action, read the full current state of the PR.

```bash
# One-shot state summary for a PR
gh pr view <pr-number> --repo <owner/repo> --json \
  number,title,state,labels,statusCheckRollup,headRefName,headRefOid,autoMergeRequest \
  | python3 -c "
import json, sys
p = json.load(sys.stdin)
print('PR:', p['number'], p['title'])
print('State:', p['state'])
print('Branch:', p['headRefName'], '@', p['headRefOid'][:8])
print('Auto-merge:', 'enabled' if p.get('autoMergeRequest') else 'disabled')
print()
print('Labels:', [l['name'] for l in p.get('labels', [])])
print()
checks = p.get('statusCheckRollup', [])
for c in checks:
    print(f\"  {c.get('context', c.get('name', '?'))}: {c.get('state', c.get('conclusion', '?'))} — {c.get('description', c.get('detailsUrl', ''))}\")
"
```

**Label interpretation:**

| Labels present | State |
|---|---|
| `agent:attempt-1` only | First build/fixup completed or in progress |
| `agent:attempt-2` | Second fixup completed or in progress |
| `agent:attempt-3` | Third (cap) fixup completed — next fixup will hit cap |
| `agent:needs-human` | Automation frozen — human review required |
| `agent:pause` | Kill switch active — all automation suppressed |
| `agent:rebase-attempt-N` | Stale-PR rebase guard counting its own cycles |
| `agent:codeowners-veto` | Rebase guard stopped — CODEOWNERS conflict |

---

## 2. Pausing a runaway loop

**Symptom:** The developer keeps making the same commit or the reviewer keeps requesting the same change. The `agent:attempt-N` labels are climbing but the diff is not converging.

**How to halt immediately:**

```bash
gh pr edit <pr-number> --repo <owner/repo> --add-label "agent:pause"
```

**What happens:**
- Any in-flight developer or reviewer run will complete its current step, but the first step of the next run checks for `agent:pause` and exits 0 with a `::notice::` annotation (no Claude invocation, no token usage).
- This is implemented in developer.yml (step 1: `Check automation pause labels`) and reviewer.yml (step `Check agent:pause kill-switch`), both merged as of RIDDIM-127.

**How to resume:**

```bash
gh pr edit <pr-number> --repo <owner/repo> --remove-label "agent:pause"
```

Then either push a commit to trigger the reviewer, or re-label the source issue with `agent:build` to restart the developer.

**Prompt drift diagnosis:**
- Look at the `agent:attempt-1` through `agent:attempt-N` progression vs the PR diff history.
- If the diff is cycling (same hunk added and reverted), the developer and reviewer prompts are not aligned. Manually push a fix commit, add `agent:pause`, and file a separate issue to improve the prompts.

---

## 3. Finding Action run logs

### Developer runs

```bash
# List recent developer runs for a specific branch
gh run list --repo <owner/repo> --workflow agent-loop.yml --branch <head-branch> --limit 10

# Download full logs for a specific run
gh run view <run-id> --repo <owner/repo> --log

# Jump to a specific step's log output
gh run view <run-id> --repo <owner/repo> --log | grep -A 50 "Run developer agent"
```

### Reviewer runs

The reviewer runs as a reusable workflow called from `agent-loop.yml`. The run appears under `agent-loop.yml` in the consumer repo, but the actual job is `reviewer-stub` within it.

```bash
gh run list --repo <owner/repo> --workflow agent-loop.yml --limit 10
gh run view <run-id> --repo <owner/repo> --log | grep -A 50 "Run reviewer agent"
```

### Finding the run for a specific PR

```bash
# Find all runs triggered by a specific PR's head branch
BRANCH=$(gh pr view <pr-number> --repo <owner/repo> --json headRefName --jq .headRefName)
gh run list --repo <owner/repo> --workflow agent-loop.yml --branch "$BRANCH"
```

---

## 4. Disabling auto-merge

If a PR is in the auto-merge queue and you need to stop it from merging:

```bash
gh pr merge <pr-number> --repo <owner/repo> --disable-auto
```

This is idempotent — if auto-merge was not enabled, the command returns a non-zero exit but has no side effects.

Re-enable auto-merge after resolving the issue:

```bash
gh pr merge <pr-number> --repo <owner/repo> --auto --squash
```

---

## 5. Manual override path for `reviewer-agent-passed` (safety-critical)

This section covers bypassing the `reviewer-agent-passed` required status check when the loop cannot complete due to infrastructure failure. **Read the decision criteria carefully before acting.**

### Decision criteria — is override safe?

Run through this checklist under pressure. **All must be YES to proceed:**

- [ ] You have personally read the PR diff and it is correct code
- [ ] The reviewer workflow is failing due to infrastructure, NOT due to a code quality concern
- [ ] At least one of the following is confirmed:
  - Anthropic API status page shows an incident: https://status.anthropic.com
  - GitHub Actions status page shows a runner outage: https://www.githubstatus.com
  - A confirmed regression in riddim-release itself is the root cause (verify with `git log --oneline -10` in riddim-release)
  - The PR was previously passing reviewer checks on an earlier commit and only the infrastructure changed

**Do NOT override if:**
- You are unsure whether the reviewer would have approved
- The reviewer is returning legitimate change requests
- The root cause is unknown

When in doubt, wait for the outage to resolve. A stuck PR is recoverable; a bad merge is not.

### Step-by-step override

> These steps require repo-admin or org-admin access. If you do not have this, escalate to @SunnyPurewal before proceeding.

1. **Document the intent** — post a PR comment before doing anything:
   ```bash
   gh pr comment <pr-number> --repo <owner/repo> --body "Manual override initiated by @<your-handle>. Reason: [PASTE REASON]. Date: $(date -u +%Y-%m-%dT%H:%MZ). Bypassing reviewer-agent-passed due to confirmed infrastructure outage."
   ```

2. **Add `agent:override` label** (create it if it doesn't exist):
   ```bash
   gh label create "agent:override" --repo <owner/repo> --color "b60205" --description "Manual override of automated review" 2>/dev/null || true
   gh pr edit <pr-number> --repo <owner/repo> --add-label "agent:override"
   ```

3. **Disable auto-merge** (so you control when the merge happens):
   ```bash
   gh pr merge <pr-number> --repo <owner/repo> --disable-auto
   ```

4. **Temporarily remove `reviewer-agent-passed` from required checks.** This requires repo-admin access:
   - Go to: `https://github.com/<owner>/<repo>/settings/branches`
   - Edit the `main` branch protection rule
   - Uncheck `reviewer-agent-passed` from required status checks
   - Click "Save changes"

   Or via API (requires `repo` scope + admin access):
   ```bash
   # Read current required checks first — do not lose existing checks
   CHECKS_WITH_REVIEWER_AGENT=$(gh api /repos/<owner>/<repo>/branches/main/protection \
     --jq '.required_status_checks.contexts')
   CHECKS_WITHOUT_REVIEWER_AGENT=$(gh api /repos/<owner>/<repo>/branches/main/protection \
     --jq '.required_status_checks.contexts | map(select(. != "reviewer-agent-passed"))')
   echo "Remaining checks after removal: $CHECKS_WITHOUT_REVIEWER_AGENT"

   # Update protection rule with reviewer-agent-passed removed
   gh api --method PATCH /repos/<owner>/<repo>/branches/main/protection/required_status_checks \
     --input - <<JSON
   {"strict":false,"contexts":${CHECKS_WITHOUT_REVIEWER_AGENT}}
JSON

   # Keep full restored set for step 6
   ```

5. **Merge manually with squash:**
   ```bash
   gh pr merge <pr-number> --repo <owner/repo> --squash \
     --subject "$(gh pr view <pr-number> --repo <owner/repo> --json title --jq .title)"
   ```

6. **Restore branch protection immediately after merge:**
   ```bash
   gh api --method PATCH /repos/<owner>/<repo>/branches/main/protection/required_status_checks \
     --input - <<JSON
   {"strict":true,"contexts":${CHECKS_WITH_REVIEWER_AGENT}}
JSON
   ```

7. **Verify protection is restored:**
   ```bash
   gh api /repos/<owner>/<repo>/branches/main/protection \
     --jq '.required_status_checks.contexts'
   ```

8. **Communication:**
   - Post in the relevant Slack channel: which PR was merged manually, who approved, why, and that branch protection has been restored
   - If multiple consumer repos were affected, notify all maintainers
   - Update the `agent:override` label description with a post-incident note

### Re-enable steps

After the infrastructure outage resolves:
1. Restore branch protection (step 6 above, if not already done)
2. Verify by opening a test PR and confirming the `reviewer-agent-passed` check runs
3. Remove `agent:override` labels from any merged PRs (cosmetic cleanup)

---

## 6. Common failure modes

### 6a. Prompt drift

**Symptom:** The developer keeps re-introducing the same defect, or the reviewer keeps requesting the same change. The `agent:attempt-N` labels climb without convergence.

**How to spot it:**
```bash
# Check attempt count
gh pr view <pr-number> --repo <owner/repo> --json labels \
  --jq '[.labels[].name | select(startswith("agent:attempt"))] | length'

# Compare consecutive commits to see if same hunk is cycling
gh pr view <pr-number> --repo <owner/repo> --json commits \
  --jq '.commits | .[-3:] | .[].oid'
```

**How to break the cycle:**
1. Add `agent:pause` (see section 2)
2. Manually push a commit resolving the sticking point
3. Remove `agent:pause` to resume
4. If the cycle was caused by an ambiguous issue description, close the PR and rewrite the issue with clearer acceptance criteria

**Status:** Anticipated, not yet observed in pilot (E6 sprint RIDDIM-129..132 did not trigger this failure mode).

### 6b. Oversize-diff false positives

**Symptom:** `guard.sh` labels the PR `agent:needs-human` with a message like `"Diff exceeds file threshold: 32 files changed (cap: 30)"` for a legitimate large PR.

**How to diagnose:**
```bash
BRANCH=$(gh pr view <pr-number> --repo <owner/repo> --json headRefName --jq .headRefName)
gh run list --repo <owner/repo> --workflow agent-loop.yml --branch "$BRANCH" --limit 3
gh run view <run-id> --repo <owner/repo> --log | grep -A 5 "Guard blocked"
```

**How to tune thresholds:**

In the consumer's `agent-loop.yml` trigger wrapper, pass `max_diff_lines` to the reviewer call:

```yaml
reviewer:
  uses: RiddimSoftware/riddim-release/.github/workflows/reviewer.yml@main
  with:
    pr_number: ${{ github.event.pull_request.number }}
    # max_diff_lines: 2000  # Uncomment to override default 500
  env:
    GUARD_MAX_FILES: 50  # Env override from default 30
```

The guard default sensitive globs can be extended (not replaced) via `GUARD_SENSITIVE_PATHS` (colon-separated). To reduce false positives on specific paths, the threshold must be tuned globally — there is no per-path allowlist today (see E6 follow-up).

**Remove `agent:needs-human` after manually inspecting the PR is safe:**
```bash
gh pr edit <pr-number> --repo <owner/repo> --remove-label "agent:needs-human"
```

**Status:** Anticipated, not yet observed in pilot (E6 sprint RIDDIM-130).

### 6c. `@main` regression rollback (blast radius: all consumers)

**Symptom:** All consumer repos fail their agent-loop workflows simultaneously, with identical error messages referencing a step in `developer.yml` or `reviewer.yml`.

**Diagnosis:**
```bash
# Find the most recent riddim-release commit
git -C /path/to/riddim-release log --oneline -5

# Check a consumer workflow run for the exact error
gh run view <run-id> --repo <consumer-owner/consumer-repo> --log 2>&1 | grep -i "error\|failed" | head -20
```

**Recovery:**
1. Revert the offending riddim-release commit:
   ```bash
   cd /path/to/riddim-release
   git revert <sha> --no-edit
   git push origin main
   ```
2. Communicate to consumer repo maintainers immediately — post in Slack with: which commit was reverted, what was broken, expected recovery time.
3. Re-trigger stuck consumer workflows:
   ```bash
   gh run rerun <run-id> --repo <consumer-owner/consumer-repo>
   ```
   Or push an empty commit to the PR branch to trigger fresh runs:
   ```bash
   git commit --allow-empty -m "chore: re-trigger agent-loop after riddim-release revert"
   git push
   ```

**Status:** Anticipated, not yet observed in pilot. Design-derived (E6 RIDDIM-131 documented this risk but did not encounter it).

### 6d. reviewer-bot 404 (App not installed) {#reviewer-bot-404}

**Symptom:** The reviewer workflow fails at the "Checkout riddim-release guard scripts" step with a 404 or authentication error.

**Diagnosis:**
```bash
gh run view <run-id> --repo <owner/repo> --log | grep -A 5 "Checkout riddim-release"
```

**Root cause:** The `reviewer-bot` GitHub App is not installed on the consumer repo (or its PAT is expired).

**Recovery:**
1. Go to: `https://github.com/organizations/RiddimSoftware/settings/installations`
2. Find reviewer-bot → Configure → add the consumer repo under "Repository access"
3. Re-trigger the workflow

**Known status (2026-04-30):** This is a confirmed blocker per RIDDIM-105 E1 smoke-test evidence. Check RIDDIM-105 for current status.

### 6e. Workflow not found / cross-repo access policy reset

**Symptom:** Consumer workflow fails with `workflow not found` or access error referencing `RiddimSoftware/riddim-release/.github/workflows/*.yml@main`.

**Root cause:** Org-level reusable workflow permissions were reset or restricted.

**Recovery:**
1. Go to: `https://github.com/organizations/RiddimSoftware/settings/actions`
2. Under "Workflow permissions", ensure `RiddimSoftware/riddim-release` is allowed as a reusable workflow source
3. Re-trigger the failed workflow

**Status:** Anticipated, not yet observed in pilot. Design-derived.

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

# Read PR labels and status checks
gh pr view <pr-number> --repo <owner/repo> --json labels,statusCheckRollup

# Check attempt count
gh pr view <pr-number> --repo <owner/repo> --json labels \
  --jq '[.labels[].name | select(startswith("agent:attempt"))] | length'

# Find runs for a PR's branch
gh run list --repo <owner/repo> --workflow agent-loop.yml \
  --branch "$(gh pr view <pr-number> --repo <owner/repo> --json headRefName --jq .headRefName)"
```

---

## 7. Stale PR rebase guard stopped automation

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
