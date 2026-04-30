# Contributing

Before merging changes to `.github/workflows/developer.yml` or developer prompt
files, run the developer workflow self-test:

```bash
gh workflow run _dev-self-test.yml \
  --repo RiddimSoftware/riddim-release \
  -f trigger_type=issue-build \
  -f issue_body="Synthetic issue body for developer workflow validation."
```

The self-test creates a `selftest/<run-id>` branch, asserts the expected
artifact exists, and cleans up the throwaway PR and branch by default.

## Reviewer workflow

Before merging changes to `.github/workflows/reviewer.yml` or reviewer prompt
files (`.github/prompts/reviewer-verdict.md`), run the reviewer workflow
self-test for both verdict branches:

```bash
gh workflow run _rev-self-test.yml \
  --repo RiddimSoftware/riddim-release \
  -f expected_verdict=approve

gh workflow run _rev-self-test.yml \
  --repo RiddimSoftware/riddim-release \
  -f expected_verdict=request-changes
```

Each run opens a throwaway PR in riddim-release, invokes the reusable reviewer
workflow with a mocked verdict (no agent API calls), asserts that the
`reviewer-agent-passed` status check matches the expected state, and then
closes and deletes the throwaway branch.
