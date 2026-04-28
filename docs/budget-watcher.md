# Budget Watcher

The budget watcher is a copy-in workflow template for consuming app repos. It
keeps release workflows on GitHub-hosted runners by default, then flips the repo
to the self-hosted macOS runner when the user-account GitHub Actions minutes are
nearly exhausted.

GitHub Actions does not provide native hosted-to-self-hosted spillover. The
workaround is to make runner selection data-driven: each workflow shim reads
repo variables and passes JSON-encoded runner label arrays into the reusable
workflows. The watcher updates those variables, so no workflow code changes are
needed when the repo changes runner mode.

Copy `templates/workflows/budget-watcher.yml` into the consuming repo as
`.github/workflows/budget-watcher.yml`.

## What It Does

Every six hours, and on manual `workflow_dispatch`, the watcher:

1. Calls the GitHub Actions billing endpoint for the repository owner.
2. Computes `total_minutes_used / included_minutes * 100`.
3. Leaves the repo in hosted mode while usage is below 85%.
4. Flips the repo to self-hosted mode at 85% or higher.
5. Resets the repo to hosted mode when usage drops below 5% after the billing
   cycle rolls over.
6. Writes a run summary showing usage and runner variables before and after the
   watcher ran.

The workflow's `GITHUB_TOKEN` only has read permissions:

```yaml
permissions:
  actions: read
  contents: read
```

Variable writes use a manually-created PAT stored as `RUNNER_BUDGET_PAT`.

The release workflows also check out the private `sunnypurewal/riddim-release`
repo to run shared scripts. Prefer a separate `RIDDIM_RELEASE_TOKEN` secret with
read-only `Contents` access to that repo. If `RUNNER_BUDGET_PAT` is a classic
PAT with `repo` access, the workflows can use it as a fallback for this private
checkout.

## Runner Variables

Consuming repos own three repo variables.

`RUNNER_PROFILE` is a semantic state marker for humans and automation. Valid
values are `hosted` and `self-hosted`.

`RUNNER_LABELS_MAC` is the JSON-encoded runner label array used by macOS jobs.

`RUNNER_LABELS_LINUX` is the JSON-encoded runner label array used by Linux jobs.
In self-hosted fallback mode, Linux jobs also run on the macOS runner because it
has `python3`, `jq`, `gh`, and AWS CLI pre-installed.

Hosted defaults:

```bash
gh variable set RUNNER_PROFILE      --repo sunnypurewal/<app> --body hosted
gh variable set RUNNER_LABELS_MAC   --repo sunnypurewal/<app> --body '["macos-15"]'
gh variable set RUNNER_LABELS_LINUX --repo sunnypurewal/<app> --body '["ubuntu-latest"]'
```

Self-hosted fallback:

```bash
gh variable set RUNNER_PROFILE      --repo sunnypurewal/<app> --body self-hosted
gh variable set RUNNER_LABELS_MAC   --repo sunnypurewal/<app> --body '["self-hosted","macOS"]'
gh variable set RUNNER_LABELS_LINUX --repo sunnypurewal/<app> --body '["self-hosted","macOS"]'
```

The self-hosted labels are exactly `self-hosted` and `macOS`. Do not add
workflow-specific labels such as `app-store-release` unless all consuming
workflow docs and watcher values are changed together.

The reusable workflows consume these values with `fromJSON(...)`:

```yaml
runs-on: ${{ fromJSON(inputs.runner_labels_mac) }}
runs-on: ${{ fromJSON(inputs.runner_labels_linux) }}
```

The copied shims provide hosted fallbacks so a repo can run before variables are
created:

```yaml
runner_labels_mac:   ${{ vars.RUNNER_LABELS_MAC || '["macos-15"]' }}
runner_labels_linux: ${{ vars.RUNNER_LABELS_LINUX || '["ubuntu-latest"]' }}
```

## Thresholds

The watcher flips to self-hosted at `>= 85%` of included Actions minutes.

That leaves headroom for in-flight or already-queued jobs after the next
six-hour poll and avoids waiting until the account is fully exhausted.

The watcher resets to hosted at `< 5%`.

GitHub billing usage drops near zero after the monthly billing cycle rolls over.
Using 5% instead of exactly zero avoids a brittle equality check and gives the
repo a deterministic way back to hosted mode soon after rollover.

## Billing Endpoint

The watcher calls:

```bash
gh api "/users/{owner}/settings/billing/actions"
```

For these repos, `{owner}` is the user account that owns the repository, for
example:

```bash
gh api /users/sunnypurewal/settings/billing/actions
```

The endpoint returns fields including:

```json
{
  "total_minutes_used": 1234,
  "included_minutes": 2000
}
```

The workflow computes:

```bash
pct = total_minutes_used / included_minutes * 100
```

If `included_minutes` is missing or zero, the template treats usage as 100% so
it fails toward self-hosted instead of continuing to spend hosted minutes.

This user-account billing endpoint is not consistently documented in all
GitHub contexts. If GitHub changes or removes it, the `Query billing` step will
fail and the repo will stay on whatever runner variables were already set.

## PAT Setup

`secrets.GITHUB_TOKEN` cannot write repository variables for this workflow. Use
a manually-created PAT and store it as `RUNNER_BUDGET_PAT` in each consuming
repo.

Required scopes:

- `read:user`
- `read:billing`
- `repo`

Do not use `gh auth token` for this secret. That token belongs to the local CLI
session and is not the long-lived watcher credential.

Provision it manually:

1. Open https://github.com/settings/tokens.
2. Create a PAT with `read:user`, `read:billing`, and `repo`.
3. Store it in the consuming repo:

```bash
gh secret set RUNNER_BUDGET_PAT --repo sunnypurewal/<app>
```

Paste the PAT when prompted. Do not commit it to the repo or write it into a
workflow file.

## Rotation

Rotate `RUNNER_BUDGET_PAT` every 90 days.

Rotation procedure:

1. Create a replacement PAT at https://github.com/settings/tokens with the same
   scopes.
2. Update the consuming repo secret:

   ```bash
   gh secret set RUNNER_BUDGET_PAT --repo sunnypurewal/<app>
   ```

3. Trigger the watcher manually:

   ```bash
   gh workflow run budget-watcher.yml --repo sunnypurewal/<app>
   ```

4. Confirm the latest run reaches the summary step:

   ```bash
   gh run list --repo sunnypurewal/<app> --workflow budget-watcher.yml --limit 3
   ```

5. Revoke the old PAT after the new run succeeds.

## Manual Override

To force hosted mode:

```bash
gh variable set RUNNER_PROFILE      --repo sunnypurewal/<app> --body hosted
gh variable set RUNNER_LABELS_MAC   --repo sunnypurewal/<app> --body '["macos-15"]'
gh variable set RUNNER_LABELS_LINUX --repo sunnypurewal/<app> --body '["ubuntu-latest"]'
```

To force self-hosted mode:

```bash
gh variable set RUNNER_PROFILE      --repo sunnypurewal/<app> --body self-hosted
gh variable set RUNNER_LABELS_MAC   --repo sunnypurewal/<app> --body '["self-hosted","macOS"]'
gh variable set RUNNER_LABELS_LINUX --repo sunnypurewal/<app> --body '["self-hosted","macOS"]'
```

Check the current values:

```bash
gh variable list --repo sunnypurewal/<app> \
  --json name,value \
  --jq '.[] | select(.name | startswith("RUNNER_"))'
```

## Failure Modes

If the watcher fails, existing workflows continue using the current repo
variables. The watcher only changes future runner selection; it does not stop
already-running jobs.

Common failures:

- `RUNNER_BUDGET_PAT` is missing or expired.
- The PAT lacks `read:user`, `read:billing`, or `repo`.
- GitHub changes the user billing endpoint.
- `jq` or `gh` is missing on the runner currently selected by
  `RUNNER_LABELS_LINUX`.
- The self-hosted runner is offline after the repo has already flipped.

Recovery steps:

1. Open the failed `budget-watcher.yml` run and read the failing step.
2. If the token failed, rotate `RUNNER_BUDGET_PAT`.
3. If runner labels point at an offline self-hosted runner, manually force
   hosted mode.
4. Trigger the watcher manually after recovery.

Optional notification is out of scope for the template, but consuming repos can
add a Slack or email notification step gated with `if: failure()` after the
summary step.

## Multi-Repo Strategy

Each consuming repo gets its own copy of `.github/workflows/budget-watcher.yml`
because the workflow writes variables in that repo.

Recommended default: create one PAT per repo and store it as that repo's
`RUNNER_BUDGET_PAT`. This has the smallest blast radius and makes rotation
auditable per app.

Alternative: use one shared PAT across several repos, such as PleasePlay,
bettrack, and BudScience. That is simpler to provision, but the PAT needs `repo`
access to every repo it manages. If it expires or leaks, every repo using it is
affected.

When adopting another repo:

1. Copy `templates/workflows/budget-watcher.yml` into the app repo.
2. Create the three `RUNNER_*` variables with hosted defaults.
3. Add `RUNNER_BUDGET_PAT`.
4. Trigger the watcher manually and confirm the summary.
5. Leave the scheduled run enabled.
