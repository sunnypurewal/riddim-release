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
