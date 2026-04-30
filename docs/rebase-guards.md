# Rebase guards

RIDDIM-91 rebase automation uses `.github/scripts/rebase-guard.sh` before any
mechanical or agent conflict-resolution push.

## Defaults

- `REBASE_MAX_ATTEMPTS=3`
- `REBASE_MAX_FILES=8`
- `REBASE_MAX_LINES=200`

Consumers can override these values from their watcher wrapper or reusable
workflow call. The defaults intentionally fail conservative: small, repeated, or
sensitive conflicts route to `agent:needs-human` with a fixed-marker comment.

## Guard outcomes

- `ok`: automation may continue.
- `attempt-cap-exceeded`: the PR already has `agent:rebase-attempt-N` at the
  configured cap. The guard adds `agent:needs-human`.
- `size-cap-exceeded`: conflicted file count or marker-line count exceeds the
  configured cap. The guard adds `agent:needs-human`.
- `codeowners-veto`: a conflicted file is owned in `CODEOWNERS` by a non-bot
  owner. The guard adds `agent:needs-human` and `agent:codeowners-veto`.

## Attempt labels

Every rebase action increments one `agent:rebase-attempt-N` label before the
action proceeds. The label is fail-conservative: if a runner crashes after
incrementing but before pushing, the next run still sees the higher attempt
number. A human can reset the sequence by removing the attempt labels after
inspection.

## Pinned watcher comment

`.github/scripts/update-watcher-status.sh` maintains a PR comment beginning
with `<!-- riddim:watcher-status -->`. Watcher runs update this comment in place
with the latest classification and action so operators do not need workflow logs
to understand the current state.

## Local smoke coverage

Run the deterministic guard smoke test with:

```bash
bash .github/scripts/rebase-guard-self-test.sh
```

It stubs `gh` and covers attempt-cap, size-cap, CODEOWNERS-veto, and bot-owned
path outcomes without mutating a real pull request.
