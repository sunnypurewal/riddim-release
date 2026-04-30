# E1 Acceptance Criteria Checklist

**Epic:** RIDDIM-93 — Provision org-level developer-bot + reviewer-bot identities and shared OAuth secrets  
**Parent initiative:** RIDDIM-91

Use this checklist to confirm E1 is fully complete before declaring the epic Done.

---

## E1-S1: developer-bot GitHub App

- [ ] `developer-bot` GitHub App created in the `RiddimSoftware` org
- [ ] Permissions set: Contents R/W, Pull requests R/W, Issues R/W, Workflows R/W, Metadata read-only
- [ ] Repository access set to **Selected repositories**: `riddim-release`, `epac`
- [ ] App installed on the org; installation ID noted

## E1-S2: reviewer-bot GitHub App

- [ ] `reviewer-bot` GitHub App created in the `RiddimSoftware` org
- [ ] Same permission set as developer-bot
- [ ] Repository access set to **Selected repositories**: `riddim-release`, `epac`
- [ ] App installed on the org; installation ID noted

## E1-S3: OAuth + bot secrets stored as org secrets

- [ ] Max-account decision documented on RIDDIM-93 (personal token vs. separate Max account)
- [ ] `CLAUDE_CODE_OAUTH_TOKEN` generated via `claude setup-token` and stored as org secret
  - Scope: selected repositories — `riddim-release`, `epac`
- [ ] `DEV_BOT_PAT` (or App installation token for developer-bot) stored as org secret
  - Scope: selected repositories — `riddim-release`, `epac`
- [ ] `REVIEWER_BOT_PAT` (or App installation token for reviewer-bot) stored as org secret
  - Scope: selected repositories — `riddim-release`, `epac`
- [ ] `gh secret list --repo RiddimSoftware/riddim-release` shows all three secrets

## E1-S4: Cross-repo reusable-workflow access policy

- [ ] `gh api /orgs/RiddimSoftware/actions/permissions` returns `enabled_repositories: all` (or `selected`) AND `allowed_actions: all` (or `selected`)
- [ ] A test workflow in a consuming repo (e.g. `epac`) can successfully `uses:` a reusable workflow from `riddim-release` without a permissions error

  **Current status (as of 2026-04-30):**  
  `enabled_repositories: all`, `allowed_actions: all`, `sha_pinning_required: false` — PASS ✓

## E1-S5: agent:* labels on both repos

- [ ] `agent:build` (`#0075ca`) created on `RiddimSoftware/riddim-release`
- [ ] `agent:pause` (`#e11d48`) created on `RiddimSoftware/riddim-release`
- [ ] `agent:needs-human` (`#f97316`) created on `RiddimSoftware/riddim-release`
- [ ] `agent:attempt-1` (`#6b7280`) created on `RiddimSoftware/riddim-release`
- [ ] `agent:attempt-2` (`#6b7280`) created on `RiddimSoftware/riddim-release`
- [ ] `agent:attempt-3` (`#6b7280`) created on `RiddimSoftware/riddim-release`
- [ ] Same six labels created on `RiddimSoftware/epac`

  **Current status (as of 2026-04-30):** All six labels created on both repos ✓

## E1-S6: Two-identity smoke test

- [ ] Throwaway PR opened on `riddim-release` **as developer-bot**
- [ ] PR approved **as reviewer-bot** using `gh pr review --approve`
- [ ] GitHub accepted the approval (no "can't approve your own PR" error)
- [ ] Approval attributed to reviewer-bot on the PR page
- [ ] Smoke-test PR closed and branch deleted
- [ ] Results posted as evidence comment on RIDDIM-91 and RIDDIM-93

---

## How to run the automated steps

```bash
# From the repo root — runs labels + policy check, then prints human-gate instructions
./scripts/setup-e1.sh all

# Individual steps:
./scripts/setup-e1.sh labels        # create/update agent:* labels
./scripts/setup-e1.sh check-policy  # verify org Actions permissions
./scripts/setup-e1.sh create-apps   # prints instructions for GitHub App creation
./scripts/setup-e1.sh store-secrets # prints instructions for storing org secrets
./scripts/setup-e1.sh smoke-test    # prints instructions for the two-identity test
```
