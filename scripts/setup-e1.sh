#!/usr/bin/env bash
# setup-e1.sh — RIDDIM-93: E1 Org Identities + Secrets Setup
#
# PURPOSE:
#   Scaffolds and documents the manual + automatable steps required to provision
#   the developer-bot and reviewer-bot GitHub App identities and org-level secrets
#   for the RIDDIM-91 autonomous PR loop.
#
# USAGE:
#   ./scripts/setup-e1.sh [--dry-run] [--step <step-name>]
#
# STEPS:
#   labels        — create/update agent:* labels on riddim-release and epac (automated)
#   check-policy  — verify org Actions permissions allow cross-repo reusable workflows (automated)
#   create-apps   — HUMAN GATE: instructions to create GitHub Apps (manual)
#   store-secrets — HUMAN GATE: instructions to store org secrets (manual)
#   smoke-test    — instructions to run the two-identity smoke test (manual)
#
# HUMAN GATE STEPS require org-admin access and cannot be automated via gh CLI
# because GitHub App creation and OAuth token issuance are not available in the API.

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
STEP="all"
ORG="RiddimSoftware"
REPOS=("riddim-release" "epac")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --step)    STEP="${2:?'--step requires an argument'}"; shift 2 ;;
    *)         STEP="$1"; shift ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
human_gate() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  HUMAN GATE — manual action required                        ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "$1"
  echo ""
}

# ── Step: labels ────────────────────────────────────────────────────────────
step_labels() {
  log "Creating agent:* labels on ${REPOS[*]}"

  declare -A LABELS=(
    ["agent:build"]="0075ca|PR opened by developer-bot"
    ["agent:pause"]="e11d48|Kill switch: stops the loop"
    ["agent:needs-human"]="f97316|Reviewer blocked, needs human"
    ["agent:attempt-1"]="6b7280|Agent attempt 1 of 3"
    ["agent:attempt-2"]="6b7280|Agent attempt 2 of 3"
    ["agent:attempt-3"]="6b7280|Agent attempt 3 of 3 (cap hit)"
  )

  for repo in "${REPOS[@]}"; do
    log "  Repo: $ORG/$repo"
    for label in "${!LABELS[@]}"; do
      IFS="|" read -r color desc <<< "${LABELS[$label]}"
      run gh label create "$label" \
        --color "$color" \
        --description "$desc" \
        --repo "$ORG/$repo" \
        --force
      run echo "    [ok] $label"
    done
  done
}

# ── Step: check-policy ──────────────────────────────────────────────────────
step_check_policy() {
  log "Checking org Actions permissions for cross-repo reusable workflow access"

  result=$(run gh api "orgs/$ORG/actions/permissions" 2>&1) || {
    warn "Could not read org Actions permissions — ensure you have org-admin scope"
    echo "$result"
    exit 1
  }

  enabled=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['enabled_repositories'])")
  allowed=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['allowed_actions'])")

  echo "  enabled_repositories: $enabled"
  echo "  allowed_actions: $allowed"

  if [[ "$enabled" == "all" || "$enabled" == "selected" ]] && \
     [[ "$allowed" == "all" || "$allowed" == "selected" ]]; then
    log "PASS: org policy allows cross-repo reusable workflow access"
  else
    warn "FAIL: org policy may block reusable workflows from consuming repos"
    warn "Fix: Settings > Actions > General > Allow all actions and reusable workflows"
    exit 1
  fi
}

# ── Step: create-apps ───────────────────────────────────────────────────────
step_create_apps() {
  human_gate "$(cat <<'INSTRUCTIONS'
STEP: Create developer-bot and reviewer-bot GitHub Apps

GitHub App creation requires a browser + org-admin access. The gh CLI does not
support App creation. Follow these steps for EACH app (developer-bot, reviewer-bot):

1. Navigate to:
   https://github.com/organizations/RiddimSoftware/settings/apps/new

2. Fill in the form:
   GitHub App name:   developer-bot   (or reviewer-bot)
   Homepage URL:      https://github.com/RiddimSoftware/riddim-release
   Webhook:           UNCHECK "Active" (we don't need webhook events)

3. Permissions — Repository permissions:
   Contents:          Read and write
   Pull requests:     Read and write
   Issues:            Read and write
   Workflows:         Read and write
   Metadata:          Read-only (required)

4. Where can this GitHub App be installed?
   Select: "Only on this account"

5. Click "Create GitHub App"

6. On the App page, note the App ID and generate a private key (Download .pem).
   Store .pem securely — you'll need it to generate installation tokens.

7. Install the App on the org:
   Settings > GitHub Apps > developer-bot > Install App
   Choose: "Selected repositories" → add riddim-release and epac

8. Repeat for reviewer-bot.

DECISION REQUIRED (Max OAuth token):
   The CLAUDE_CODE_OAUTH_TOKEN is a per-user Max plan OAuth token.
   Option A: Use the user's personal Max token (single quota, simple).
   Option B: Provision a separate Max account for bots (cleaner audit).
   Document the choice in a comment on RIDDIM-93 before E1-S3.
INSTRUCTIONS
)"
}

# ── Step: store-secrets ─────────────────────────────────────────────────────
step_store_secrets() {
  human_gate "$(cat <<'INSTRUCTIONS'
STEP: Generate Claude OAuth token and store org secrets

After App creation (step create-apps), run the following to store secrets.
Replace placeholders with actual values.

1. Generate CLAUDE_CODE_OAUTH_TOKEN:
   Run: claude setup-token
   Copy the output token.

2. Store org secrets with selected-repository access:

   # CLAUDE_CODE_OAUTH_TOKEN (for both repos):
   gh secret set CLAUDE_CODE_OAUTH_TOKEN \
     --org RiddimSoftware \
     --repos riddim-release,epac \
     --body "<paste token here>"

   # DEV_BOT_PAT — generate from developer-bot App installation token OR
   # a fine-grained PAT from developer-bot account (prefer App token):
   gh secret set DEV_BOT_PAT \
     --org RiddimSoftware \
     --repos riddim-release,epac \
     --body "<developer-bot token>"

   # REVIEWER_BOT_PAT:
   gh secret set REVIEWER_BOT_PAT \
     --org RiddimSoftware \
     --repos riddim-release,epac \
     --body "<reviewer-bot token>"

3. Verify secrets are visible in the repo:
   gh secret list --repo RiddimSoftware/riddim-release
   gh secret list --repo RiddimSoftware/epac

   Expected output includes: CLAUDE_CODE_OAUTH_TOKEN, DEV_BOT_PAT, REVIEWER_BOT_PAT
INSTRUCTIONS
)"
}

# ── Step: smoke-test ────────────────────────────────────────────────────────
step_smoke_test() {
  human_gate "$(cat <<'INSTRUCTIONS'
STEP: Smoke-test the two-identity PR flow

After secrets are stored, validate that GitHub accepts approvals from a
separate identity (reviewer-bot cannot approve developer-bot's own PR).

1. As developer-bot, create a throwaway branch and open a PR:
   git checkout -b smoke-test/e1-identity-check
   echo "# smoke test" >> smoke-test.md
   git add smoke-test.md && git commit -m "chore: E1 identity smoke test"
   git push origin smoke-test/e1-identity-check
   gh pr create \
     --repo RiddimSoftware/riddim-release \
     --title "chore: E1 identity smoke test" \
     --body "Smoke test for RIDDIM-93 — delete after verification." \
     --base main

2. As reviewer-bot, approve the PR:
   gh pr review <PR-NUMBER> \
     --repo RiddimSoftware/riddim-release \
     --approve \
     --body "Smoke test approval from reviewer-bot."

3. Verify on the PR page:
   - The approval is attributed to reviewer-bot (not developer-bot)
   - No "you can't approve your own PR" error appears
   - GitHub shows 1 approval from reviewer-bot

4. Close and delete the smoke-test PR:
   gh pr close <PR-NUMBER> --repo RiddimSoftware/riddim-release --delete-branch

5. Post results as a comment on RIDDIM-91 and RIDDIM-93.
INSTRUCTIONS
)"
}

# ── Main ────────────────────────────────────────────────────────────────────
case "$STEP" in
  labels)       step_labels ;;
  check-policy) step_check_policy ;;
  create-apps)  step_create_apps ;;
  store-secrets)step_store_secrets ;;
  smoke-test)   step_smoke_test ;;
  all)
    step_labels
    echo ""
    step_check_policy
    echo ""
    step_create_apps
    echo ""
    step_store_secrets
    echo ""
    step_smoke_test
    ;;
  *)
    echo "Unknown step: $STEP"
    echo "Usage: $0 [labels|check-policy|create-apps|store-secrets|smoke-test|all]"
    exit 1
    ;;
esac
