# Adopting riddim-release in an iOS app

> **Status:** stub. Filled in as part of Epic 1 (story RIDDIM-108: "Adopt-this-framework guide"). The goal is that someone other than the author can take a fresh iOS app repo to first TestFlight build in <30 minutes by following this document.

## Outline (to be filled in)

1. **Prerequisites**
   - Apple Developer team membership (riddimsoftware team `ZG82TFXU3C`)
   - AWS access — `appstore/connect-api` and `appstore/distribution-cert` Secrets Manager entries
   - GitHub user-account access — settings to register self-hosted runners and create environments

2. **One-time provisioning**
   - Confirm the AWS OIDC trust policy on `AWS_RELEASE_ROLE_ARN` covers the new repo
   - Query the Apple numeric `APPLE_APP_ID` via the ASC API
   - Set repo variables: `APPLE_APP_ID`, `BUNDLE_ID`, `TEAM_ID`, `SCHEME`, `PRIMARY_LOCALE`, `RUNNER_PROFILE=hosted`, `RUNNER_LABELS_MAC=["macos-15"]`, `RUNNER_LABELS_LINUX=["ubuntu-latest"]`
   - Set repo secrets: `AWS_RELEASE_ROLE_ARN`, `KEYCHAIN_PASSWORD`, `RUNNER_BUDGET_PAT`
   - Register a self-hosted macOS runner with labels `self-hosted` and `macOS` (optional but recommended for budget fallback)
   - Create the `app-store-release` GitHub Environment with required-reviewers

3. **Repo scaffolding**
   - Copy `templates/workflows/*.shim.yml` → `.github/workflows/`
   - Copy `templates/workflows/budget-watcher.yml` → `.github/workflows/`
   - Copy `templates/fastlane/*` → `ios/fastlane/`, fill in the ERB placeholders
   - Add the 5-line `import_from_git` `Fastfile`
   - Populate `ios/fastlane/metadata/<locale>/*.txt` with App Store copy
   - Capture screenshots into `ios/fastlane/screenshots/<locale>/`
   - (Optional) record App Preview via `scripts/marketing/record-app-preview.sh`

4. **First build**
   - `gh workflow run build-deploy.yml -f bump=patch -f dry_run=true` — confirm green
   - Re-run without `dry_run` — confirm TestFlight build appears
   - Smoke-test on device

5. **First ASC submission**
   - QA approves the draft GitHub Release
   - Publish the release — `release-app-store.yml` fires
   - Approve via the GitHub Environment gate
   - Build is submitted with phased release

## Related docs

- `runner-setup.md` — registering and provisioning a self-hosted macOS runner
- `aws-provisioning.md` — OIDC trust policy, secret formats
- `asc-provisioning.md` — querying APPLE_APP_ID, ASC API key scope
- `budget-watcher.md` — how the hosted/self-hosted flip works
- `aso-playbook.md` — keeping keywords/screenshots/preview fresh between releases
