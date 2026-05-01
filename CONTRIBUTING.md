# Contributing to riddim-release

Thank you for your interest in contributing. riddim-release is the shared
GitHub Actions release infrastructure for Riddim iOS apps and websites. It
packages workflows, Fastlane lanes, and App Store Connect scripts that
consuming repos call as reusable workflows — the goal is boring, reliable
release operations across multiple apps.

## Ways to contribute

- **Bug reports** — something in a workflow, script, or Fastlane lane is
  broken or behaving unexpectedly
- **Documentation improvements** — adoption guides, configuration reference,
  or this file
- **Workflow fixes and improvements** — better error handling, new workflow
  inputs, performance
- **New features** — additional reusable workflows, script utilities, or
  Fastlane lanes that fit the release pipeline scope

## Reporting bugs

Open a [GitHub Issue](https://github.com/RiddimSoftware/riddim-release/issues).
Include:

- Which workflow or script is affected (e.g. `build-deploy.yml`,
  `scripts/release/compute_version.py`)
- The consumer repo type (iOS app, website, or riddim-release itself)
- The full error message or unexpected output
- The output of a `dry_run: true` run if the issue is in `build-deploy.yml`
  or `release-app-store.yml`
- The `RIDDIM_RELEASE_REF` the consumer is pinned to

## Suggesting changes

For significant changes — new workflows, changes to the reusable workflow
contract, new required variables or secrets — open an issue first and describe
the use case. This avoids wasted effort on changes that don't fit the project's
scope or approach.

For small fixes (typos, error message improvements, doc clarifications), a PR
without a prior issue is fine.

## Development setup

```bash
# Python dependencies (release scripts and analytics)
pip install -r scripts/release/requirements.txt

# Ruby dependencies (Fastlane, for testing lane changes)
cd ios && bundle install
```

[actionlint](https://github.com/rhysd/actionlint) is useful for local workflow
validation:

```bash
brew install actionlint
```

## Making changes

1. Fork the repo and create a branch from `main`.
2. Use `feature/<short-description>` or `fix/<short-description>` for branch
   names.
3. Keep PRs focused — one logical change per PR. Split unrelated fixes into
   separate PRs.

## Testing changes

### Workflow changes

Changes to `build-deploy.yml` or any job it calls:

```bash
gh workflow run self-test.yml \
  --repo RiddimSoftware/riddim-release \
  -f dry_run=true
```

Changes to `release-app-store.yml`:

```bash
gh workflow run self-test-release-app-store.yml \
  --repo RiddimSoftware/riddim-release
```

Both self-tests create a throwaway branch and PR, assert the expected workflow
behavior, and clean up afterward.

### Python unit tests

```bash
python -m pytest scripts/release/
```

Some tests make live App Store Connect API calls and require ASC credentials to
be configured locally. If you don't have credentials, run the tests that don't
require them:

```bash
python -m pytest scripts/release/ -m "not live"
```

For analytics and Jira scripts:

```bash
python3 -m unittest discover scripts/analytics
python3 -m unittest discover scripts/jira
```

### Workflow syntax

```bash
actionlint .github/workflows/*.yml
```

## Pull request guidelines

- **Small and focused.** A PR that does one thing is easier to review and
  safer to merge.
- **Describe what and why.** The PR description should explain what changed
  and why, not just restate the diff. If the change fixes a bug, describe the
  root cause.
- **Link issues.** Reference the issue your PR resolves with `Closes #<number>`
  in the description.
- **Include test evidence.** For workflow changes, paste the self-test run URL
  or relevant log output. For script changes, paste the `pytest` output.

## Code style

- **Shell scripts:** `set -euo pipefail` at the top, hyphens in filenames
  (e.g. `fetch-secret.sh`).
- **Python:** snake_case for identifiers, type hints for new functions.
- **YAML workflows:** two-space indentation, explicit `name:` on every step.

## License

By contributing, you agree that your changes will be released under the
[MIT License](LICENSE) that covers this repository.
