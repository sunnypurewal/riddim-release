#!/usr/bin/env bash
# enroll-repo.sh — Enroll a consumer repo in the autonomous PR loop.
#
# Usage: scripts/enroll-repo.sh <owner/repo>
# Example: scripts/enroll-repo.sh RiddimSoftware/epac
#
# What this script does:
#   1. Creates all agent:* labels on the target repo (idempotent via --force).
#   2. Prints the branch protection settings URL and required settings.
#   3. Verifies CLAUDE_CODE_OAUTH_TOKEN org secret is accessible to the repo.
#   4. Prints a checklist of remaining manual steps.
#
# Requirements:
#   - gh CLI authenticated with a token that has repo and admin:org scope.
#   - The riddim-release workflows must be on main before enrolling.

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: scripts/enroll-repo.sh <owner/repo>

Enroll a consumer repository in the autonomous PR loop.

Arguments:
  owner/repo    GitHub repository to enroll (e.g. RiddimSoftware/epac)

Options:
  -h, --help    Show this help message and exit

Example:
  scripts/enroll-repo.sh RiddimSoftware/epac
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Error: missing required argument <owner/repo>" >&2
  usage >&2
  exit 1
fi

REPO="$1"

# Validate format
if [[ "$REPO" != */* ]]; then
  echo "Error: argument must be in <owner/repo> format (got: $REPO)" >&2
  exit 1
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

echo ""
echo "=========================================="
echo " Enrolling $REPO in the autonomous PR loop"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Step 1: Create agent:* labels (idempotent)
# ---------------------------------------------------------------------------

echo "Step 1: Creating agent:* labels on $REPO..."
echo ""

labels=(
  "agent:pause|6a737d|Manual override that halts autonomous workflows on a PR or issue."
  "agent:needs-human|d73a4a|Applied when attempt cap is hit; blocks automation, requires human review."
  "agent:attempt-1|ffd8a8|Attempt counter: first developer fix-up attempt."
  "agent:attempt-2|ffb56b|Attempt counter: second developer fix-up attempt."
  "agent:attempt-3|ff922b|Attempt counter: third and final default attempt."
  "agent:rebase-attempt-1|c5def5|Rebase attempt counter: first stale-PR rebase attempt."
  "agent:rebase-attempt-2|8db7e8|Rebase attempt counter: second stale-PR rebase attempt."
  "agent:rebase-attempt-3|5319e7|Rebase attempt counter: third and final default stale-PR attempt."
  "agent:codeowners-veto|b60205|Applied when rebase conflicts touch human-owned CODEOWNERS paths."
)

for label in "${labels[@]}"; do
  IFS='|' read -r name color description <<<"$label"
  gh label create "$name" \
    --repo "$REPO" \
    --color "$color" \
    --description "$description" \
    --force
  printf '  [ok] %s\n' "$name"
done

echo ""
echo "  All agent:* labels created."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Branch protection instructions
# ---------------------------------------------------------------------------

echo "Step 2: Branch protection on main (manual — cannot be fully automated)"
echo ""
echo "  Open this URL to configure branch protection:"
echo ""
echo "  https://github.com/$REPO/settings/branches"
echo ""
echo "  Apply these settings to the 'main' branch rule:"
echo ""
echo "  Setting                                    Value"
echo "  -------------------------------------------+------------------------------"
echo "  Require a pull request before merging      Yes"
echo "  Required approving reviews                 1"
echo "  Dismiss stale reviews on new pushes        Yes (recommended)"
echo "  Require status checks to pass              Yes"
echo "  Required status check name                 reviewer-agent-passed"
echo "  Require branches to be up to date          Yes"
echo "  Allow auto-merge                           Yes"
echo "  Automatically delete head branches         Yes"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Verify CLAUDE_CODE_OAUTH_TOKEN is accessible
# ---------------------------------------------------------------------------

echo "Step 3: Verifying CLAUDE_CODE_OAUTH_TOKEN org secret is accessible to $REPO..."
echo ""

# The GitHub API endpoint below reports org secrets that are available to the target repo.
SECRET_CHECK=$(gh api "repos/$REPO/actions/organization-secrets" --jq '.secrets[].name' 2>/dev/null || echo "")

if echo "$SECRET_CHECK" | grep -q "^CLAUDE_CODE_OAUTH_TOKEN$"; then
  echo "  [ok] CLAUDE_CODE_OAUTH_TOKEN is accessible to $REPO."
else
  echo "  [WARN] CLAUDE_CODE_OAUTH_TOKEN was not found in the repo's secret list."
  echo "         This may mean:"
  echo "           a) The secret is not yet granted to this repo, or"
  echo "           b) The caller token lacks admin:org scope to read secrets."
  echo ""
  echo "         To grant access manually:"
  echo "           https://github.com/organizations/$OWNER/settings/secrets/actions"
  echo "         Find CLAUDE_CODE_OAUTH_TOKEN and add '$REPO_NAME' to the repository list."
fi

echo ""

# ---------------------------------------------------------------------------
# Step 4: Checklist of remaining manual steps
# ---------------------------------------------------------------------------

echo "Step 4: Remaining manual steps"
echo ""
echo "  Complete these steps before running the smoke test:"
echo ""
echo "  [ ] 1. Copy trigger wrapper workflow:"
echo "         cp docs/agent-loop/trigger-wrapper-template.yml \\"
echo "            /path/to/$REPO_NAME/.github/workflows/agent-loop.yml"
echo "         git -C /path/to/$REPO_NAME add .github/workflows/agent-loop.yml"
echo "         git -C /path/to/$REPO_NAME commit -m 'chore: add autonomous PR loop trigger wrapper'"
echo "         git -C /path/to/$REPO_NAME push origin main"
echo ""
echo "  [ ] 2. Configure branch protection on main (see Step 2 URL above)."
echo ""
echo "  [ ] 3. Add CODEOWNERS to $REPO covering:"
echo "         - .env* and secrets"
echo "         - .github/workflows/"
echo "         - fastlane/ or release pipeline dirs"
echo "         - infra/ or terraform/"
echo "         - auth-related paths"
echo ""
echo "  [ ] 4a. If enabling stale-PR rebases, wire your watcher to call:"
echo "         RiddimSoftware/riddim-release/.github/workflows/agent-rebase.yml@main"
echo "         with REBASE_MAX_ATTEMPTS, REBASE_MAX_FILES, and REBASE_MAX_LINES"
echo "         overrides only when the defaults are too strict for this repo."
echo ""
echo "  [ ] 4. Verify CLAUDE_CODE_OAUTH_TOKEN and REVIEWER_BOT_PAT are accessible"
echo "         to this repo (check Step 3 output above)."
echo ""
echo "  [ ] 5. Smoke test:"
echo "         a. Create a Jira test ticket with a simple, clear acceptance criterion and push a throwaway branch containing the ticket key."
echo "         b. Add the Jira agent:pr label to the ticket after pushing a branch containing the ticket key."
echo "         c. Watch GitHub Actions — developer workflow should start in ~30s."
echo "         d. A PR should open, then the reviewer workflow should run."
echo "         e. If approved, auto-merge should land without human intervention."
echo ""
echo "  Docs: https://github.com/RiddimSoftware/riddim-release/blob/main/docs/agent-loop/README.md"
echo ""
echo "=========================================="
echo " Enrollment preparation complete for $REPO"
echo "=========================================="
echo ""
