# Sprint autopilot

`sprint-autopilot.yml` periodically checks a configured Jira board and this
repository's pull requests. If the active sprint has no incomplete Jira issues
and the repo has no open pull requests, it closes the active sprint and starts
the next future sprint.

The scheduled workflow is gated by `SPRINT_AUTOPILOT_ENABLED=true`. Manual runs
are always allowed and default to dry run.

## Repository configuration

Variables:

- `SPRINT_AUTOPILOT_ENABLED`: set to `true` to allow scheduled runs to mutate Jira.
- `SPRINT_AUTOPILOT_DRY_RUN`: set to `true` to keep scheduled runs read-only.
- `JIRA_BASE_URL`: Jira site URL, for example `https://riddim.atlassian.net`.
- `JIRA_BOARD_ID`: Jira Software board ID to inspect.
- `NEXT_SPRINT_DURATION_DAYS`: optional, defaults to `14` when the next sprint has no dates.

Secrets:

- `JIRA_EMAIL`: Atlassian account email for the automation user.
- `JIRA_API_TOKEN`: Atlassian API token for the automation user.

The workflow uses the built-in `GITHUB_TOKEN` to read open pull requests.

## Cadence

GitHub Actions schedule granularity is five minutes. Change the cron expression
in `.github/workflows/sprint-autopilot.yml` to set the desired check interval.

## Local dry run

```bash
DRY_RUN=true \
JIRA_BASE_URL=https://riddim.atlassian.net \
JIRA_BOARD_ID=123 \
JIRA_EMAIL=you@example.com \
JIRA_API_TOKEN=... \
GITHUB_TOKEN=... \
GITHUB_REPOSITORY=RiddimSoftware/riddim-release \
python3 scripts/jira/sprint_autopilot.py
```
