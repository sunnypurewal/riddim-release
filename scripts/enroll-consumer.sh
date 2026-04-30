#!/usr/bin/env bash
# enroll-consumer.sh — Enroll a consumer repository in the autonomous PR loop.
#
# Usage: scripts/enroll-consumer.sh [--dry-run] <owner/repo>
#
# What this script automates (Steps 2-6 of docs/agent-loop/onboarding.md):
#   1. Creates all agent:* labels on the target repo (idempotent via --force).
#   2. Grants org secrets to the target repo (CLAUDE_CODE_OAUTH_TOKEN, DEV_BOT_PAT,
#      REVIEWER_BOT_PAT). Skips if already granted.
#   3. Opens a PR in the consumer repo with the agent-loop.yml trigger wrapper
#      and a CODEOWNERS scaffold. Skips if already open or merged.
#   4. Configures branch protection on main to require reviewer-agent-passed.
#      Preserves existing required checks.
#   5. Prints instructions for manual steps (App installs, review the PR).
#
# Options:
#   --dry-run   Print every action as the exact gh command without executing it.
#               Output is copy-paste safe for manual step-through.
#
# Requirements:
#   - gh CLI authenticated with admin:org + repo scope.
#   - The riddim-release repo must be a sibling directory or on PATH/accessible.
#   - This script does NOT auto-rollback on failure. Re-run to pick up where
#     it left off — each step checks current state before acting.
#
# Idempotency:
#   - Labels: gh label create --force is a no-op if label already matches
#   - Secrets: reads current repo list before writing; skips if already present
#   - Trigger PR: skips if an open PR touching .github/workflows/agent-loop.yml exists
#   - Branch protection: reads current checks before merging in reviewer-agent-passed
#
# Failure handling:
#   - Any non-zero step exits the script with the failing gh command printed.
#   - Partial enrollment is recoverable by re-running.
#   - Do NOT auto-rollback (could remove pre-existing rules).

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

DRY_RUN=false
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      sed -n '1,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      REPO="$1"
      shift
      ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: missing required argument <owner/repo>" >&2
  echo "Usage: $0 [--dry-run] <owner/repo>" >&2
  exit 1
fi

if [[ "$REPO" != */* ]]; then
  echo "Error: argument must be in <owner/repo> format (got: $REPO)" >&2
  exit 1
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIDDIM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

# Like run() but captures output — in dry-run prints the command and returns a
# placeholder value so the calling code doesn't break.
capture() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*" >&2
    echo "<dry-run-placeholder>"
  else
    "$@"
  fi
}

step() {
  echo ""
  echo "──────────────────────────────────────────────────────"
  echo "  Step $1: $2"
  echo "──────────────────────────────────────────────────────"
}

skip() {
  echo "  [skip] $*"
}

ok() {
  echo "  [ok]   $*"
}

warn() {
  echo "  [warn] $*" >&2
}

# ---------------------------------------------------------------------------
# Pre-flight: verify repo exists and caller has access
# ---------------------------------------------------------------------------

echo ""
echo "Enrolling ${REPO} in the autonomous PR loop${DRY_RUN:+ (DRY RUN)}."
echo ""

if [[ "$DRY_RUN" != "true" ]]; then
  if ! gh repo view "$REPO" >/dev/null 2>&1; then
    echo "Error: repo '$REPO' not found or caller lacks access." >&2
    exit 1
  fi
  ok "Repo $REPO accessible."
else
  echo "[dry-run] gh repo view ${REPO}"
fi

# ---------------------------------------------------------------------------
# Step 1: Create agent:* labels (idempotent via --force)
# ---------------------------------------------------------------------------

step 1 "Create agent:* labels on ${REPO}"

declare -a LABELS=(
  "agent:build|fb8c00|Triggers the autonomous developer workflow on an issue."
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

for label in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<<"$label"
  run gh label create "$name" \
    --repo "$REPO" \
    --color "$color" \
    --description "$description" \
    --force
done
ok "All agent:* labels created/updated."

# ---------------------------------------------------------------------------
# Step 2: Grant org secrets to the consumer repo
# ---------------------------------------------------------------------------

step 2 "Grant org secrets to ${REPO}"

REPO_ID="$(capture gh api "/repos/${REPO}" --jq .id)"

for secret in CLAUDE_CODE_OAUTH_TOKEN DEV_BOT_PAT REVIEWER_BOT_PAT; do
  # Check if already granted
  if [[ "$DRY_RUN" != "true" ]]; then
    already_granted="$(gh api "/orgs/${OWNER}/actions/secrets/${secret}/repositories" \
      --jq "[.repositories[].full_name] | any(. == \"${REPO}\")" 2>/dev/null || echo "false")"
    if [[ "$already_granted" == "true" ]]; then
      skip "${secret} already granted to ${REPO}"
      continue
    fi
  fi

  run gh api \
    --method PUT \
    "/orgs/${OWNER}/actions/secrets/${secret}/repositories/${REPO_ID}"
  ok "${secret} granted to ${REPO}"
done

# ---------------------------------------------------------------------------
# Step 3: Open a PR in the consumer repo with trigger wrapper + CODEOWNERS scaffold
# ---------------------------------------------------------------------------

step 3 "Open enrollment PR in ${REPO}"

BRANCH_NAME="setup/enroll-agent-loop"
TEMPLATE="${RIDDIM_ROOT}/docs/agent-loop/trigger-wrapper-template.yml"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: trigger-wrapper-template.yml not found at ${TEMPLATE}" >&2
  echo "       Is the script running from inside the riddim-release repo?" >&2
  exit 1
fi

# Check if an enrollment PR is already open or merged
if [[ "$DRY_RUN" != "true" ]]; then
  existing_pr="$(gh pr list --repo "$REPO" \
    --search "head:${BRANCH_NAME}" \
    --state all \
    --json number,state \
    --jq '.[0] | "\(.state):\(.number)"' 2>/dev/null || true)"

  if [[ -n "$existing_pr" ]]; then
    state="${existing_pr%%:*}"
    number="${existing_pr##*:}"
    if [[ "$state" == "MERGED" ]]; then
      skip "Enrollment PR #${number} already merged — skipping trigger-wrapper step."
    else
      skip "Enrollment PR #${number} already open (state: ${state}) — skipping."
    fi
    # Continue to remaining steps even if PR exists
    SKIP_PR=true
  else
    SKIP_PR=false
  fi
else
  SKIP_PR=false
fi

if [[ "${SKIP_PR:-false}" == "false" ]]; then
  # Clone or use a temp worktree approach — we need a local checkout of the consumer
  # Since we cannot guarantee a local checkout exists, we use the GitHub API to push
  # the files directly via the contents API (simpler than requiring a local clone).

  TRIGGER_CONTENT="$(base64 < "$TEMPLATE")"
  CODEOWNERS_CONTENT="$(base64 <<'CODEOWNERS'
# CODEOWNERS — Scaffold generated by riddim-release enroll-consumer.sh
# Owned paths require human review — the autonomous reviewer will not merge without it.
# Update handles and add paths specific to this repository.

# Secret management
**/secrets/**              @OWNER_HANDLE
**/*.env                   @OWNER_HANDLE
**/*secret*                @OWNER_HANDLE

# Release pipelines
fastlane/                  @OWNER_HANDLE
ios/fastlane/              @OWNER_HANDLE
Gemfile                    @OWNER_HANDLE
Gemfile.lock               @OWNER_HANDLE

# Infrastructure and auth
infra/                     @OWNER_HANDLE
**/auth/**                 @OWNER_HANDLE
.github/workflows/         @OWNER_HANDLE

# App metadata / entitlements (mobile apps)
**/*.entitlements          @OWNER_HANDLE
**/Info.plist              @OWNER_HANDLE
**/*.xcconfig              @OWNER_HANDLE
CODEOWNERS
)"

  # Get default branch to base the PR off
  DEFAULT_BRANCH="$(capture gh api "/repos/${REPO}" --jq .default_branch)"
  if [[ "$DEFAULT_BRANCH" == "<dry-run-placeholder>" ]]; then
    DEFAULT_BRANCH="main"
  fi

  # Create the branch
  MAIN_SHA="$(capture gh api "/repos/${REPO}/git/refs/heads/${DEFAULT_BRANCH}" --jq .object.sha)"

  if [[ "$DRY_RUN" != "true" ]]; then
    run gh api \
      --method POST \
      "/repos/${REPO}/git/refs" \
      --field "ref=refs/heads/${BRANCH_NAME}" \
      --field "sha=${MAIN_SHA}"

    # Push agent-loop.yml
    run gh api \
      --method PUT \
      "/repos/${REPO}/contents/.github/workflows/agent-loop.yml" \
      --field "message=chore: add autonomous PR loop trigger wrapper" \
      --field "content=${TRIGGER_CONTENT}" \
      --field "branch=${BRANCH_NAME}"

    # Push CODEOWNERS scaffold (only if CODEOWNERS doesn't exist)
    codeowners_exists="$(gh api "/repos/${REPO}/contents/CODEOWNERS" \
      --jq .name 2>/dev/null || true)"
    if [[ -z "$codeowners_exists" ]]; then
      run gh api \
        --method PUT \
        "/repos/${REPO}/contents/CODEOWNERS" \
        --field "message=chore: scaffold CODEOWNERS for autonomous PR loop" \
        --field "content=${CODEOWNERS_CONTENT}" \
        --field "branch=${BRANCH_NAME}"
    else
      skip "CODEOWNERS already exists in ${REPO} — not overwriting."
    fi

    # Open PR
    PR_URL="$(gh pr create \
      --repo "$REPO" \
      --title "chore: enroll autonomous PR agent loop" \
      --body "$(cat <<EOF
## Enrollment PR — Autonomous PR Agent Loop

This PR was opened by \`riddim-release/scripts/enroll-consumer.sh\`.

**What this adds:**
- \`.github/workflows/agent-loop.yml\` — trigger wrapper that calls the reusable developer and reviewer workflows from riddim-release
- \`CODEOWNERS\` scaffold (if not already present) — update \`@OWNER_HANDLE\` to your team before merging

**Before merging:**
- [ ] Update \`CODEOWNERS\` with correct owner handles
- [ ] Confirm branch protection on \`main\` requires \`reviewer-agent-passed\` (see [onboarding.md](https://github.com/RiddimSoftware/riddim-release/blob/main/docs/agent-loop/onboarding.md))
- [ ] Confirm \`developer-bot\` and \`reviewer-bot\` GitHub Apps are installed on this repo

**After merging:**
Run the smoke test from the [onboarding runbook](https://github.com/RiddimSoftware/riddim-release/blob/main/docs/agent-loop/onboarding.md#step-7--smoke-test).
EOF
)" \
      --base "$DEFAULT_BRANCH" \
      --head "$BRANCH_NAME" 2>&1)"
    ok "Enrollment PR opened: ${PR_URL}"
  else
    echo "[dry-run] gh api --method POST /repos/${REPO}/git/refs --field ref=refs/heads/${BRANCH_NAME} --field sha=<main-sha>"
    echo "[dry-run] gh api --method PUT /repos/${REPO}/contents/.github/workflows/agent-loop.yml --field message=... --field content=<base64> --field branch=${BRANCH_NAME}"
    echo "[dry-run] gh api --method PUT /repos/${REPO}/contents/CODEOWNERS --field message=... --field content=<base64> --field branch=${BRANCH_NAME}"
    echo "[dry-run] gh pr create --repo ${REPO} --title 'chore: enroll autonomous PR agent loop' --base ${DEFAULT_BRANCH} --head ${BRANCH_NAME}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Configure branch protection on main to require reviewer-agent-passed
# ---------------------------------------------------------------------------

step 4 "Configure branch protection on ${REPO}/main"

if [[ "$DRY_RUN" != "true" ]]; then
  # Read existing required checks to avoid overwriting them
  existing_checks="$(gh api "/repos/${REPO}/branches/main/protection" \
    --jq '.required_status_checks.contexts // []' 2>/dev/null || echo "[]")"

  # Check if reviewer-agent-passed is already in the list
  already_has_check="$(echo "$existing_checks" \
    | python3 -c "import json,sys; checks=json.load(sys.stdin); print('true' if 'reviewer-agent-passed' in checks else 'false')")"

  if [[ "$already_has_check" == "true" ]]; then
    skip "reviewer-agent-passed already in required checks for ${REPO}/main"
  else
    # Merge in reviewer-agent-passed
    new_checks="$(echo "$existing_checks" \
      | python3 -c "import json,sys; checks=json.load(sys.stdin); checks.append('reviewer-agent-passed'); print(json.dumps(checks))")"

    run gh api \
      --method PATCH \
      "/repos/${REPO}/branches/main/protection/required_status_checks" \
      --field "strict=true" \
      --field "contexts=${new_checks}"
    ok "reviewer-agent-passed added to required checks on ${REPO}/main"
  fi
else
  echo "[dry-run] gh api /repos/${REPO}/branches/main/protection --jq '.required_status_checks.contexts'  # read existing checks"
  echo "[dry-run] gh api --method PATCH /repos/${REPO}/branches/main/protection/required_status_checks --field strict=true --field 'contexts=[...existing...,\"reviewer-agent-passed\"]'"
fi

# ---------------------------------------------------------------------------
# Step 5: Manual steps reminder
# ---------------------------------------------------------------------------

step 5 "Remaining manual steps"
echo ""
echo "  The following steps require manual action and cannot be automated:"
echo ""
echo "  1. Install developer-bot GitHub App on ${REPO}:"
echo "     https://github.com/organizations/${OWNER}/settings/installations"
echo "     Find developer-bot → Configure → add ${REPO_NAME} to repository access"
echo ""
echo "  2. Install reviewer-bot GitHub App on ${REPO}:"
echo "     Same URL as above — find reviewer-bot and add ${REPO_NAME}"
echo ""
echo "  3. Review and merge the enrollment PR opened in Step 3 above:"
echo "     - Update CODEOWNERS handles before merging"
echo "     - Confirm branch protection from Step 4 looks correct"
echo ""
echo "  4. Run the smoke test per onboarding.md Step 7:"
echo "     https://github.com/RiddimSoftware/riddim-release/blob/main/docs/agent-loop/onboarding.md#step-7--smoke-test"
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "──────────────────────────────────────────────────────"
echo "  Enrollment automation complete for ${REPO}${DRY_RUN:+ (DRY RUN)}"
echo "──────────────────────────────────────────────────────"
echo ""
