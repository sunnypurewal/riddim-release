# Budget Watcher

Budget-aware runner selection is implemented by the RIDDIM-41 epic, not by the
bootstrap docs story.

Current v1 bootstrap contract:

- Consuming repos set `RUNNER_PROFILE` to `hosted` or `self-hosted`.
- Consuming repos set `RUNNER_LABELS_MAC` to a JSON-encoded array string.
- Consuming repos set `RUNNER_LABELS_LINUX` to a JSON-encoded array string.
- Workflow shims pass those strings into reusable workflows.
- Reusable workflows call `fromJSON(inputs.runner_labels_*)`.

Hosted defaults:

```bash
gh variable set RUNNER_PROFILE      --repo sunnypurewal/<app> --body hosted
gh variable set RUNNER_LABELS_MAC   --repo sunnypurewal/<app> --body '["macos-15"]'
gh variable set RUNNER_LABELS_LINUX --repo sunnypurewal/<app> --body '["ubuntu-latest"]'
```

Self-hosted macOS fallback:

```bash
gh variable set RUNNER_PROFILE --repo sunnypurewal/<app> --body self-hosted
gh variable set RUNNER_LABELS_MAC \
  --repo sunnypurewal/<app> \
  --body '["self-hosted","macOS"]'
gh variable set RUNNER_LABELS_LINUX \
  --repo sunnypurewal/<app> \
  --body '["self-hosted","macOS"]'
```

RIDDIM-41 will fill in the scheduled watcher, budget detection, and automatic
variable flip.
