# E10 — Rebase Guards Reference

Rebase guards prevent unbounded retry loops, large-surface agent invocations, and
automated conflict resolution touching human-owned paths. They are evaluated by
`rebase-guard.sh` before every mechanical rebase (E8) and every agent conflict
resolution (E9).

---

## Guard outcomes

| Decision | Meaning |
|---|---|
| `ok` | All checks passed; proceed with rebase. |
| `attempt-cap-exceeded` | The PR has hit `REBASE_MAX_ATTEMPTS` rebase labels. |
| `size-cap-exceeded` | The conflict surface exceeds file-count or marker-line thresholds. |
| `codeowners-veto` | A conflicting file is owned in CODEOWNERS by a non-bot principal. |

Every non-`ok` outcome applies `agent:needs-human` to the PR, posts or updates a
fixed-marker comment (see [Comment markers](#comment-markers) below), and exits the
calling workflow with code 0 so the watcher run itself stays green.

---

## Default thresholds

| Variable | Default | Meaning |
|---|---|---|
| `REBASE_MAX_ATTEMPTS` | `3` | Maximum `agent:rebase-attempt-N` labels before cap. |
| `REBASE_MAX_FILES` | `8` | Maximum number of conflicting files. |
| `REBASE_MAX_LINES` | `200` | Maximum total conflict-marker lines across all files. |
| `REBASE_BOT_OWNER_RE` | `(^|/)(developer-bot|reviewer-bot)(\[bot\])?$` | Regex matching CODEOWNERS owners that are treated as bot-owned (not vetoed). |

---

## Overriding thresholds per consumer repo

Pass env vars on the `workflow_call` invocation inside the consumer repo's trigger
wrapper (`agent-loop.yml`). Example:

```yaml
jobs:
  rebase:
    uses: RiddimSoftware/riddim-release/.github/workflows/agent-rebase.yml@main
    with:
      consumer_repo: ${{ github.repository }}
      pr_number: ${{ inputs.pr_number }}
      rebase_max_attempts: 5      # override — higher cap for busy repos
      rebase_max_files: 12        # override — allow larger conflict surface
      rebase_max_lines: 400       # override — allow more marker lines
    secrets: inherit
```

The `agent-rebase.yml` workflow accepts `rebase_max_attempts`, `rebase_max_files`,
and `rebase_max_lines` as typed workflow inputs and forwards them as env vars to
`rebase-guard.sh`.

`auto-rebase.yml` (E8 mechanical path) currently hard-codes `REBASE_MAX_ATTEMPTS`
to `3` in the workflow and does not currently support per-repo override.

---

## Attempt counter

### How it increments

The counter is encoded in GitHub labels: `agent:rebase-attempt-1`,
`agent:rebase-attempt-2`, `agent:rebase-attempt-3`. The guard script reads the
highest `N` present, checks against the cap, and (when `REBASE_INCREMENT_ATTEMPT=true`)
removes the old label and adds the next one before the rebase proceeds.

E8 (`auto-rebase.yml`) increments inline in the guard step. E9 (`agent-rebase.yml`)
sets `REBASE_INCREMENT_ATTEMPT=true` when calling `rebase-guard.sh`.

### Reset condition

The counter resets **only on PR merge** — specifically when all `agent:rebase-attempt-N`
labels are removed as part of the merge cleanup. It does **not** reset on:

- A new commit push to the PR branch
- A `main`-advance that makes the PR `behind` again
- A comment or review

This is intentional: a push that doesn't resolve the underlying issue should not
give the agent fresh quota.

**Manual reset:** remove all `agent:rebase-attempt-*` labels from the PR. This
immediately re-enables the guard and restores the full attempt budget.

### Counter drift

If a workflow run increments the attempt label then crashes before pushing, the next
run will see N+1 attempts but only N actual pushes. The guard fails conservatively in
this case — the human sees the PR is at the cap even though fewer pushes happened.

To recover: remove the `agent:rebase-attempt-N` label manually. The guard will
treat the PR as being at N-1 attempts on the next run.

---

## CODEOWNERS veto

The guard fetches the consuming repo's `CODEOWNERS` file (checked at
`.github/CODEOWNERS`, then `CODEOWNERS`, then `docs/CODEOWNERS`) and matches each
conflicting file against its patterns using Python's `fnmatch`.

A file is **vetoed** when it matches a CODEOWNERS rule whose owner list contains at
least one principal that does not match `REBASE_BOT_OWNER_RE`. Common non-bot
principals: `@my-org/security-team`, `@alice`, `@my-org/platform`.

A file is **not vetoed** when:
- No CODEOWNERS rule matches it.
- All matched owners match `REBASE_BOT_OWNER_RE` (developer-bot / reviewer-bot).
- The CODEOWNERS file does not exist in the repo.

`*` is allowed and still passes.

---

## Comment markers

The guard writes PR comments under fixed HTML-comment markers so subsequent runs
update in place rather than posting duplicates:

| Marker | Trigger |
|---|---|
| `<!-- riddim:rebase-guard:attempts -->` | Attempt cap exceeded. |
| `<!-- riddim:rebase-guard:size -->` | Conflict-size cap exceeded. |
| `<!-- riddim:rebase-guard:codeowners -->` | CODEOWNERS veto triggered. |
| `<!-- riddim:watcher-status -->` | Overall watcher run summary (updated every run). |

These markers are distinct from `<!-- riddim:agent-rebase:failure -->` (used by the
E9 validation / verification failure path) and from any markers used by
`claude-code-action` or other bot workflows.

---

## Script reference

```
.github/scripts/rebase-guard.sh <pr-number> [repo]
```

- `$1` — PR number (integer).
- `$2` / `$GITHUB_REPOSITORY` — `owner/repo` of the consuming repository.
- Env: `REBASE_MAX_ATTEMPTS`, `REBASE_MAX_FILES`, `REBASE_MAX_LINES`,
  `REBASE_INCREMENT_ATTEMPT` (`true` to bump label), `REBASE_BOT_OWNER_RE`.
- Stdout line 1: decision string (`ok`, `attempt-cap-exceeded`, …).
- Stdout line 2: JSON object with `decision`, `reason`, `files`,
  `conflicting_files`, `conflict_marker_lines`, `current_attempt`, `max_attempts`.
- Exit 0 always (guard blocks are surfaced via the decision string, not exit code).

```
.github/scripts/update-watcher-status.sh <owner> <repo> <pr_number> <state> <action>
```

Upserts the `<!-- riddim:watcher-status -->` comment on the PR. Called by E8 and E9
after every run to keep the pinned comment current.

---

## Related

- [`failure-runbook.md`](failure-runbook.md) — diagnosis when a PR is stuck at the cap
- [`onboarding.md`](onboarding.md) — consumer enrollment guide including label setup
- [RIDDIM-138](https://riddim.atlassian.net/browse/RIDDIM-138) — this epic
- [RIDDIM-136 / E8](https://riddim.atlassian.net/browse/RIDDIM-136) — mechanical rebase
- [RIDDIM-137 / E9](https://riddim.atlassian.net/browse/RIDDIM-137) — agent conflict resolution
