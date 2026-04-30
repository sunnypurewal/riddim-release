# E6 Pilot Evidence

## Pilot 1 — Trivial change (RIDDIM-129)

**Issue:** https://github.com/RiddimSoftware/epac/issues/301
**PR:** not opened — developer workflow failed before opening a PR
**Outcome:** failed
**Wall-clock:** label applied at 2026-04-30T06:34:06Z → developer workflow failed at 2026-04-30T06:34:10Z (4 seconds); no PR was produced

### Phase timing

| Phase | Timestamp | Duration |
|-------|-----------|---------|
| agent:build label applied | 2026-04-30T06:34:06Z | — |
| Developer workflow started | 2026-04-30T06:34:10Z | +4s |
| Developer workflow completed | 2026-04-30T06:34:10Z | <1s |
| PR opened | — | — |
| Reviewer workflow started | — | — |
| Reviewer workflow completed | — | — |
| Auto-merge enabled | — | — |
| PR merged | — | — |

### Observations

- **GitHub Issues was disabled on epac.** The `agent:build` label trigger requires issues to be present on the repo, but `has_issues` was `false`. The pilot observer enabled issues via `PATCH /repos/RiddimSoftware/epac` before creating the issue. This is an enrollment gap — the enrollment checklist (`docs/agent-loop-enrollment.md`) does not mention enabling GitHub Issues.
- **Developer workflow run `25151087027` fired on the `issues: labeled` event** (correct trigger) but completed immediately with `conclusion: failure` and zero jobs. No jobs started at all, indicating a pre-job validation failure.
- **Root cause: `trigger_type` mismatch.** `agent-loop.yml` on epac passes `trigger_type: issue-build` (hyphen) to the reusable `developer.yml`, but the reusable workflow declares the only valid values as `issue_labeled` and `changes_requested` (underscore). The reusable workflow exits with `::error::trigger_type must be issue_labeled or changes_requested.` for unknown values. Because `workflow_call` validates inputs before starting jobs, the run fails with zero jobs.
- **Simultaneous unrelated activity**: a human PR (#302, RIDDIM-139) was opened within 34 seconds of the label event; multiple other PRs (#291–#299) were already in flight on epac. The epac loop was under active development during this pilot run.
- **All prior agent-loop.yml runs also show `failure`**: runs for `pull_request` and `pull_request_review` events created minutes before the pilot (IDs 25151076832, 25151054262, 25151029001, 25150960040, 25150550825, 25150358723) all failed. The loop has not successfully completed a full round-trip on this repo at any point during the observation window.
- **`secrets: inherit` vs named secrets**: the reusable `developer.yml` declares `claude_code_oauth_token` and `dev_bot_pat` as required named secrets. `secrets: inherit` passes them transitively, which is valid per GitHub Actions docs — this is unlikely to be the root cause, but cannot be fully ruled out without a successful run.
- **Reviewer bot login mismatch (secondary)**: `agent-loop.yml` checks `github.event.pull_request.user.login == 'developer-bot'` (plain login), but the GitHub App bot login format is `riddim-riddim-developer-bot[bot]`. This would have prevented the reviewer workflow from firing even if a PR had been opened.

### Token usage

Not available — the developer agent never ran; no Claude invocation occurred.

### Surprises

1. **Issues disabled** — a production epac setting that was not in the enrollment checklist. Required manual API intervention before the pilot could start.
2. **Zero-job failure** — the workflow call failed before any job started, producing no logs to inspect via `gh run view`. The failure mode was invisible without reading the reusable workflow source directly and comparing input schemas.
3. **`trigger_type` schema drift** — `agent-loop.yml` was written with `issue-build` (hyphen) but the reusable workflow was (re)written to expect `issue_labeled` (underscore). This is a consumer/library interface divergence that would need schema versioning or a CI check to catch.
4. **Concurrent human activity** — the pilot ran while epac was under active development, making it harder to distinguish pilot-specific failures from pre-existing loop breakage.

### Recommended fixes (for E6-S4 tuning, not this pilot)

1. Add "GitHub Issues must be enabled" to `docs/agent-loop-enrollment.md`.
2. Fix `agent-loop.yml` to pass `trigger_type: issue_labeled` and `trigger_type: changes_requested` (underscores).
3. Fix `agent-loop.yml` reviewer job `if` condition: replace `'developer-bot'` with the actual GitHub App bot slug (e.g. `'riddim-riddim-developer-bot[bot]'`).
4. Add a schema-parity CI check or at minimum a comment in `agent-loop.yml` listing the accepted `trigger_type` values.

---

## Pilot 1 (retry) — Trivial change (RIDDIM-129)

**Issue:** https://github.com/RiddimSoftware/epac/issues/304
**PR:** not opened — entire workflow fails at startup before any job runs
**Outcome:** failed
**Wall-clock:** label at 2026-04-30T06:41:55Z → startup_failure at 2026-04-30T06:41:58Z (+3s); 25-min monitoring window expired with no developer run, no PR

### Phase timing

| Phase | Timestamp | Duration |
|-------|-----------|---------|
| agent:build label applied | 2026-04-30T06:41:55Z | — |
| Developer workflow started | — | — |
| Developer workflow completed | — | — |
| PR opened | — | — |
| Reviewer workflow started | — | — |
| Reviewer workflow completed | — | — |
| Auto-merge enabled | — | — |
| PR merged | — | — |

### Observations

- **Root cause: `rebase-watcher` input schema mismatch.** The `agent-loop.yml` rebase-watcher job passes `owner`, `repo`, `build_cmd`, and `test_cmd` as `with:` inputs, but `rebase-watcher.yml`'s `workflow_call` definition (recently updated) only declares `consumer_repo`, `base_branch`, `autonomous_label`, and `dry_run`. GitHub Actions validates all `with:` inputs for all jobs at parse time — unknown input names cause a `startup_failure` for the entire workflow run before any job can execute. This affects every trigger event (issues, pull_request, push, schedule, workflow_dispatch), not just the push/schedule events that would actually run the rebase-watcher job.
- **Pre-flight checks passed — the trigger_type fix merged.** Both pre-flight checks from the E6 instructions passed before triggering the pilot: (1) `grep -c "issue_labeled"` in epac's `agent-loop.yml` returned 1; (2) `grep -c "riddim-riddim-developer-bot"` in riddim-release's `reviewer.yml` returned 2. The trigger_type fix (PR #303 was CONFLICTING; the fix landed via PR #292/RIDDIM-96 squash merge) was confirmed on main. However, the rebase-watcher input mismatch introduced by a separate PR (rebase-watcher.yml redesign in riddim-release) broke all workflow runs.
- **Zero-job failure on all event types, not just issues.** Run IDs 25151349508 (issues), 25151375528 (push), 25151337475 (pull_request), and 7 subsequent runs all show `startup_failure` with zero jobs. The pattern was consistent across the full 25-minute observation window. No developer agent ever invoked Claude.
- **Issues event correctly fired within 3 seconds.** The `issues: types: [labeled]` trigger worked as intended — run 25151349508 fired at 06:41:58Z, 3 seconds after the label was applied. The trigger pipeline itself is healthy; only the workflow body is broken.
- **Active epac development during the observation window.** PRs #302, #303, and other branches were in flight during the pilot. Multiple pushes and PR events continuously triggered new startup_failure runs throughout the observation window, confirming the failure is not isolated to the issue_labeled event.
- **PR #303 (trigger_type fix) had CONFLICTING merge state** when the pre-flight check initially ran. The fix was already present on main via a prior merge (PR #292); PR #303 was a redundant/conflicting branch that was never merged. This created pre-flight confusion but did not affect the outcome.

### Token usage

Not captured — no Claude invocation occurred. The developer agent never started.

### Surprises / failure modes

1. **New bug introduced between pilots.** The `trigger_type` mismatch from Pilot 1 was fixed, but a new bug was introduced: the `rebase-watcher.yml` input schema changed and `agent-loop.yml` was not updated to match. The consumer/library interface gap recurred in a different location.
2. **startup_failure vs failure.** Pilot 1 produced `conclusion: failure` with zero jobs; this retry produced `conclusion: startup_failure` with zero jobs. Both result in no developer agent running, but `startup_failure` indicates GitHub detected the input mismatch before attempting job evaluation — a slightly different failure mode suggesting schema validation at parse time.
3. **Pre-flight checks are insufficient.** The pre-flight checks verified `trigger_type` and bot login fixes but did not verify the `rebase-watcher` input compatibility. A more complete pre-flight would validate all `with:` keys against each referenced reusable workflow's declared inputs.
4. **The loop has never successfully completed a round-trip on epac.** Every "Autonomous PR Loop" run observed in this and the previous pilot shows `failure` or `startup_failure`. The infrastructure is not yet in a state where a live pilot can succeed.
