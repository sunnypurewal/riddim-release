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
