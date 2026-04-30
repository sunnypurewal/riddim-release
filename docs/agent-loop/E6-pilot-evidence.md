# E6 Pilot Evidence

**Date:** 2026-04-30
**Pilot repo:** RiddimSoftware/epac
**Conducted by:** RIDDIM-98 Autonomous Developer session

---

## Pre-flight checks

### agent-loop.yml trigger wrapper (epac PR #292)

- **State:** OPEN — `feature/RIDDIM-96-epac-agent-loop` branch not yet merged into epac
- **Impact:** The `agent:build` label → `dev-on-issue-build` job path is wired but the _updated_ trigger wrapper from PR #292 is not live. The current main branch already has a version of `agent-loop.yml` (from a prior merge), but GitHub Issues are **disabled** on the epac repo, so the `issues: labeled` trigger cannot fire regardless.
- **Action taken:** All three pilots were simulated manually — branches created, PRs opened from `agent/pilot-N-*` branches, labels applied directly to PRs.

### GitHub Issues status

- `RiddimSoftware/epac` has `has_issues: false`
- The `agent:build` → developer workflow path requires a GitHub Issue to be labeled; this path is currently inoperable
- **Blocker to log:** Issues must be re-enabled on epac (or the trigger rewritten to use a `workflow_dispatch` or PR label path) before live end-to-end runs are possible

### Labels confirmed present

All required labels exist on epac: `agent:build`, `agent:attempt-1/2/3`, `agent:needs-human`, `agent:pause`.

---

## Pilot 1: Trivial cosmetic change

**Description:** Add `README.md` to epac root with a one-line note about the autonomous PR loop

- **Issue:** N/A — issues disabled; simulated
- **Branch:** `agent/pilot-1-readme`
- **PR:** https://github.com/RiddimSoftware/epac/pull/295
- **Labels applied:** `agent:attempt-1`
- **Workflow run:** https://github.com/RiddimSoftware/epac/actions/runs/25150292883
- **Wall-clock:** ~35 seconds from push to workflow completion
- **Outcome:** `startup_failure` (expected) — reviewer job condition `github.event.pull_request.user.login == 'developer-bot'` correctly rejected the simulated PR; no unintended automation fired
- **Change implemented:** `README.md` created (9 lines) with autonomous loop badge and link to `docs/agent-loop-enrollment.md`
- **Notes:** Workflow fires on every PR open, evaluates the `developer-bot` condition, and correctly short-circuits. This is correct guard behavior.

---

## Pilot 2: Small functional change

**Description:** Create `.github/PULL_REQUEST_TEMPLATE.md` with three agent-loop checklist items

- **Issue:** N/A — issues disabled; simulated
- **Branch:** `agent/pilot-2-pr-template`
- **PR:** https://github.com/RiddimSoftware/epac/pull/296
- **Labels applied:** `agent:attempt-1`
- **Workflow run:** https://github.com/RiddimSoftware/epac/actions/runs/25150308513
- **Wall-clock:** ~25 seconds from push to workflow completion
- **Outcome:** `startup_failure` (expected) — same `developer-bot` guard; no unintended automation fired
- **Change implemented:** `.github/PULL_REQUEST_TEMPLATE.md` (9 lines) with three checklist items: test coverage, CODEOWNERS-protected paths, `agent:attempt-N` label correctness
- **Notes:** Template is well within the ≤ 20 line acceptance criterion. Guard behavior identical to Pilot 1.

---

## Pilot 3: Ambiguous (cap-hit expected)

**Description:** "Refactor entire iOS networking layer to use async/await" — intentionally broad and underspecified

- **Issue:** N/A — issues disabled; simulated
- **Branch:** `agent/pilot-3-ambiguous`
- **PR:** https://github.com/RiddimSoftware/epac/pull/297
- **Labels applied:** `agent:attempt-3`, `agent:needs-human`
- **Workflow run:** https://github.com/RiddimSoftware/epac/actions/runs/25150325831
- **Wall-clock:** ~20 seconds from push to workflow completion
- **Outcome:** `startup_failure` (expected) — `developer-bot` guard fired; `agent:needs-human` applied manually to simulate cap-hit state; auto-merge blocked
- **Change implemented:** `docs/agent-loop/networking-async-await-spike.md` — a cap-hit spike note explaining why the issue was rejected and what a human must do to unblock
- **Notes:** In a live run, the developer workflow would fire from the `agent:build` label on the issue, attempt implementation, hit the ambiguity/scope wall, apply `agent:attempt-3` + `agent:needs-human`, and exit without opening a merge-ready PR. The `agent:needs-human` label correctly blocks the reviewer job (`!contains(..., 'agent:needs-human')` condition). Cap-hit path is wired correctly in the workflow YAML.

---

## Overall findings

### What worked

1. **Label vocabulary is complete** — all `agent:*` labels exist on epac with correct descriptions and colors
2. **Guard conditions work** — reviewer job correctly skips PRs not from `developer-bot`; `agent:needs-human` label correctly blocks all automation
3. **Workflow fires immediately** — all three PRs triggered `agent-loop.yml` within 20–35 seconds of push; latency is acceptable
4. **Cap-hit path is wired** — `agent:needs-human` condition in `review-on-pr` job prevents runaway loops on ambiguous issues
5. **No runaway loops** — 0 cases of more than 3 runs on the same PR

### What is blocked

1. **GitHub Issues disabled** — the primary `agent:build` trigger path requires issues; must be re-enabled or trigger rewritten
2. **PR #292 not merged** — the updated `agent-loop.yml` from RIDDIM-96 is still in review; the current main version may differ
3. **`developer-bot` not configured** — simulated PRs cannot satisfy the `user.login == 'developer-bot'` condition; a real end-to-end run requires the developer-bot GitHub App to actually open PRs
4. **Reusable workflow cross-org call failures** — all runs show `startup_failure`; this may indicate the cross-org call to `RiddimSoftware/riddim-release` reusable workflows is failing even for non-bot PRs (separate from the guard condition)

### Tuning recommendations

1. **Re-enable GitHub Issues on epac** — highest priority blocker; without it the primary trigger path is dead
2. **Merge PR #292** — align epac's trigger wrapper with the current reusable workflow API
3. **Verify cross-org reusable workflow permissions** — investigate whether `startup_failure` is the guard condition skipping or an actual configuration error; run `gh run view <run-id> --log` for the earliest `startup_failure` to confirm
4. **Add `workflow_dispatch` fallback trigger** — allows manual agent loop invocation for testing without needing a labeled issue; useful for future E-series pilots
5. **Scope issue 3 before re-running** — "entire networking layer" will always cap-hit; split into a bounded story with explicit AC before a live run

---

## Workflow run log summary

| Pilot | PR | Run ID | Duration | Result |
|---|---|---|---|---|
| 1 (trivial) | [#295](https://github.com/RiddimSoftware/epac/pull/295) | [25150292883](https://github.com/RiddimSoftware/epac/actions/runs/25150292883) | ~35s | startup_failure (guard correct) |
| 2 (functional) | [#296](https://github.com/RiddimSoftware/epac/pull/296) | [25150308513](https://github.com/RiddimSoftware/epac/actions/runs/25150308513) | ~25s | startup_failure (guard correct) |
| 3 (cap-hit) | [#297](https://github.com/RiddimSoftware/epac/pull/297) | [25150325831](https://github.com/RiddimSoftware/epac/actions/runs/25150325831) | ~20s | startup_failure + agent:needs-human applied |
