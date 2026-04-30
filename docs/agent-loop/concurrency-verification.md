# Concurrency Cancellation Verification

**Ticket:** RIDDIM-128  
**Last verified against:** `riddim-release@19898ca` on 2026-04-30  
**Verified by:** E5 lane agent

---

## Summary

Both `developer.yml` and `reviewer.yml` have correctly configured `concurrency:` blocks with `cancel-in-progress: true`. New runs for the same PR/issue cancel any in-flight run in the same concurrency group.

---

## Concurrency configuration

### developer.yml

```yaml
concurrency:
  group: developer-${{ github.repository }}-${{ inputs.issue_number }}
  cancel-in-progress: true
```

**Group key:** `developer-<org/repo>-<issue_or_pr_number>`

- `inputs.issue_number` is set to the issue number on `issue_labeled` trigger and to the PR number on `changes_requested` trigger (per the caller wrapper template).
- This means: for a given repo + issue/PR number, only one developer run is active at a time. A second push or re-label cancels the first.

**Assessment:** Correct. The group key is unambiguous and scoped to the repo + PR number.

### reviewer.yml

```yaml
concurrency:
  group: reviewer-agent-pr-${{ inputs.pr_number }}
  cancel-in-progress: true
```

**Group key:** `reviewer-agent-pr-<pr_number>`

- `inputs.pr_number` is passed by the caller wrapper from `github.event.pull_request.number`.
- This means: for a given PR, only one reviewer run is active at a time. Pushing a new commit while the reviewer is running will cancel the in-flight run.

**Assessment:** Correct for the single-repo pilot (one consumer). If multiple consumers call the same reusable workflow simultaneously for different PRs on different repos, the group key `reviewer-agent-pr-<number>` could theoretically collide if two repos have the same PR number. However, reusable `workflow_call` concurrency groups are evaluated in the context of the calling workflow's repository, so in practice there is no cross-repo collision.

---

## Verification method

Static analysis of YAML at the above SHA. The `concurrency.cancel-in-progress: true` flag is the correct setting — it instructs GitHub Actions to cancel any pending or in-progress run in the same group when a new run is queued.

**Live verification** (performed on riddim-release self-test infrastructure):

1. **developer.yml:** On `developer-self-test.yml` (PR #58), two rapid pushes were observed to result in the first run being cancelled. The Actions UI showed the first run's status as "Cancelled" with the second run proceeding normally.

2. **reviewer.yml:** On `reviewer-self-test.yml`, the `concurrency` group correctly prevents two simultaneous reviewer runs on the same PR.

**Common typo to watch for:** Using `${{ github.event.pull_request.number }}` instead of `${{ inputs.pr_number }}` in a `workflow_call` context. The event context is not populated for called workflows — only `inputs` values are. Both current files correctly use `inputs.*`. This is the typo called out in the RIDDIM-128 ticket risk notes.

---

## Finding

**Both workflows are correctly configured.** No code change is required for this ticket.

The concurrency keys are:
- Scoped to repo + PR/issue number (developer)
- Scoped to PR number within the calling repo's namespace (reviewer)
- Both use `cancel-in-progress: true`

Evidence: static analysis confirmed above; live cancellation behavior observed in prior self-test runs.
