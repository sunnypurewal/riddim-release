# E1 Smoke Test Evidence — RIDDIM-105

**Date:** 2026-04-30  
**Ticket:** [RIDDIM-105](https://riddim.atlassian.net/browse/RIDDIM-105) — [E1-S6] Smoke-test two-identity PR flow on riddim-release manually  
**Actions run:** https://github.com/RiddimSoftware/riddim-release/actions/runs/25149719523

---

## Results Summary

| Check | Result | Notes |
|-------|--------|-------|
| `CLAUDE_CODE_OAUTH_TOKEN` non-empty | PASS | Length: 109 chars |
| `DEV_BOT_APP_ID` non-empty | PASS | Length: 7 chars |
| `REVIEWER_BOT_APP_ID` non-empty | PASS | Length: 7 chars |
| developer-bot token mint | PASS | Token minted for RiddimSoftware org |
| developer-bot repo access | PASS | Installation has access to 10 repositories |
| developer-bot login | `riddim-developer-bot[bot]` | Confirmed via app slug |
| reviewer-bot token mint | **FAIL** | App not installed on org — see blocker below |
| reviewer-bot login | N/A (blocked) | |
| Distinct identities verified | N/A (blocked) | Cannot compare until reviewer-bot is installed |
| Cross-bot PR approval | N/A (blocked) | Cannot test until reviewer-bot is installed |

---

## Secrets Availability (all pass)

- `CLAUDE_CODE_OAUTH_TOKEN`: present (length 109)
- `DEV_BOT_APP_ID`: present (length 7)
- `DEV_BOT_PRIVATE_KEY`: present (token minted successfully)
- `REVIEWER_BOT_APP_ID`: present (length 7)
- `REVIEWER_BOT_PRIVATE_KEY`: present in org secrets (not verified — blocked by installation gap)

---

## Bot Identity Results

### developer-bot (PASS)

- **App slug:** `riddim-developer-bot`
- **Bot login:** `riddim-developer-bot[bot]`
- **App ID:** 3551890
- **Installation:** Installed on `RiddimSoftware` org (10 repos accessible)
- **Token mint:** Success — `actions/create-github-app-token@v1` created installation token
- **Verification:** `gh api /installation/repositories` returned `total_count: 10`

### reviewer-bot (BLOCKED — not installed)

- **App slug:** `riddim-reviewer-bot`
- **Bot login (expected):** `riddim-reviewer-bot[bot]`
- **App ID:** 3551935
- **App created:** 2026-04-30T05:18:58Z (same day as this smoke test)
- **Installation:** NOT installed on `RiddimSoftware` org
- **Token mint:** FAILED — `actions/create-github-app-token@v1` returns 404 (no installation found)
- **Error:** `Not Found — GET /users/RiddimSoftware/installation`

---

## Blocker: reviewer-bot App Not Installed

The `riddim-reviewer-bot` GitHub App was created (App ID: 3551935) but was never installed on the `RiddimSoftware` organization. Without an org installation, no installation tokens can be minted, and the cross-bot PR approval test cannot proceed.

**Unblock action (requires org admin — human gate):**

1. Navigate to: https://github.com/apps/riddim-reviewer-bot/installations/new
2. Select the `RiddimSoftware` organization
3. Grant access to `All repositories` (or at minimum `riddim-release`)
4. Click Install

After installation, re-run the smoke test workflow on this branch:
```
gh workflow run _smoke-test-e1.yml --repo RiddimSoftware/riddim-release --ref feature/RIDDIM-105-e1-smoke-test --field test_name=all
```

---

## Cross-Bot PR Approval

Not tested — blocked pending reviewer-bot installation. Once installed:

1. Open a throwaway PR using developer-bot token
2. Approve using reviewer-bot token (`gh pr review --approve`)
3. Confirm no "you can't approve your own PR" error (different App = different GitHub identity)

Expected result: PASS (the two Apps are separate GitHub App registrations with distinct identities)

---

## Workflow File

The smoke-test workflow was created at `.github/workflows/_smoke-test-e1.yml` on branch `feature/RIDDIM-105-e1-smoke-test`. It was also temporarily pushed to `main` to enable `workflow_dispatch` triggering (GitHub requires the workflow file to exist on the default branch). The workflow was removed from `main` after testing and remains only on the feature branch.

---

## Next Steps

1. **Human gate:** Org admin installs `riddim-reviewer-bot` App on `RiddimSoftware` org
2. Re-run smoke test — all jobs should pass
3. Run cross-bot PR approval test
4. Mark RIDDIM-105 Done and RIDDIM-93 (E1) Done
5. Unblock E2/E3/E5
