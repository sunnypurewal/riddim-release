# App Store Connect Analytics Collection

This guide wires a consuming app repo to the `riddim-release` analytics artifact
pipeline. The output is repo-owned evidence under
`docs/analytics/app-store-connect/`, not a hosted dashboard.

## Required Access

Create an App Store Connect API key with the narrowest role that can perform the
operation:

- Admin: required to create the first Analytics Report request for an app.
- Sales and Reports: can read Analytics Reports after requests exist and can
  download Sales/Trends reports.
- Finance: can read Analytics Reports and Finance reports when the account has
  Finance access.

Apple may delay reports, suppress low-volume data, or add privacy protections.
Treat missing rows as unknown unless the report explicitly proves zero activity.

## Repo Setup

Copy the workflow shim:

```bash
mkdir -p .github/workflows docs/analytics docs/analytics/benchmarks
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/v1/templates/workflows/collect-asc-analytics.shim.yml" \
  -o .github/workflows/collect-asc-analytics.yml
```

Add `docs/analytics/report-catalog.json`:

```json
{
  "app": {
    "slug": "pleaseplay",
    "app_id": "1234567890",
    "bundle_id": "com.riddim.pleaseplay",
    "provider_id": "123456",
    "vendor_number": "87654321",
    "primary_locale": "en-US"
  },
  "output_dir": "docs/analytics/app-store-connect",
  "retention": {
    "backfill_days": 90,
    "raw_retention": "indefinite"
  },
  "business_context": {
    "jira_keys": [],
    "marketing_channel": "app-store"
  },
  "families": {
    "analytics": {
      "enabled": true,
      "access_type": "ONGOING",
      "granularities": ["DAILY"],
      "reports": [
        {
          "category": "APP_STORE_ENGAGEMENT",
          "name": "App Store Discovery and Engagement Detailed"
        }
      ]
    },
    "sales": {
      "enabled": true,
      "reports": [
        {
          "frequency": "DAILY",
          "report_type": "SALES",
          "report_subtype": "SUMMARY",
          "version": "1_0"
        }
      ]
    },
    "finance": {
      "enabled": false,
      "reports": [
        {
          "region_code": "US",
          "report_type": "FINANCIAL"
        }
      ]
    }
  }
}
```

Set secrets for non-dry-runs:

```bash
gh secret set ASC_KEY_ID
gh secret set ASC_ISSUER_ID
gh secret set ASC_PRIVATE_KEY < AuthKey_<key-id>.p8
```

The workflow also uses `RUNNER_LABELS_LINUX`; if unset, the shim falls back to
`["ubuntu-latest"]`.

## First Backfill

Start with a dry-run:

```bash
gh workflow run collect-asc-analytics.yml \
  -f report_date=2026-04-27 \
  -f families=analytics,sales,finance \
  -f dry_run=true
```

If the app has no Analytics Report request yet, run once with an Admin key:

```bash
gh workflow run collect-asc-analytics.yml \
  -f report_date=2026-04-27 \
  -f families=analytics \
  -f dry_run=false \
  -f create_requests=true
```

Apple can take one to two days to generate the first analytics reports. Rerun
without `create_requests` after reports become available.

## Daily Operation

The shim includes a daily schedule. Scheduled runs collect enabled report
families, normalize rows, write `manifest.json`, schema snapshots, `summary.md`,
and upload the artifact as a GitHub Actions artifact. To preserve generated
files in the repo, download the workflow artifact and commit it on a review
branch; do not silently mutate `main`.

Expected artifact tree:

```text
docs/analytics/app-store-connect/pleaseplay/2026-04-27_2026-04-27/
  manifest.json
  summary.md
  raw/
  schema/
  normalized/
  evaluation/
```

## Interpreting Manifests

Use `manifest.json` as the source of truth for completeness:

- `downloaded` or `unchanged`: raw file is present and checksummed.
- `unavailable`: no Analytics Report request exists or the report does not
  exist for the app.
- `delayed`: Apple has not finished generating that report instance.
- `missing_segment`: an instance exists, but one or more downloadable segments
  were absent.
- `permission_blocked`: API key role cannot access the family.
- `thresholded` or `empty`: parsing found no rows or Apple withheld data; this
  is insufficient data, not proof of zero activity.

## Campaign Evaluation

Create a goal file:

```json
{
  "jira_key": "RIDDIM-123",
  "baseline_window": {"start": "2026-04-01", "end": "2026-04-07"},
  "campaign_window": {"start": "2026-04-08", "end": "2026-04-14"},
  "metrics": [
    {
      "name": "impressions",
      "source_column": "Impressions",
      "target_delta": 0.1,
      "direction": "increase"
    }
  ]
}
```

Save it at `docs/analytics/benchmarks/RIDDIM-123.json`, then run:

```bash
gh workflow run collect-asc-analytics.yml \
  -f report_date=2026-04-14 \
  -f dry_run=false \
  -f evaluate_jira_key=RIDDIM-123
```

The evaluation Markdown cites the manifest, raw files, and normalized files used
for each metric. Link that Markdown artifact from the Jira ticket when reviewing
whether the campaign met its benchmark.

## Local Fixture Check

From this repo:

```bash
python3 scripts/analytics/collect_asc_analytics.py \
  --config scripts/analytics/fixtures/report-catalog.fixture.json \
  --report-date 2026-04-27 \
  --families analytics,sales,finance \
  --dry-run
python3 -m unittest discover -s scripts/analytics -p 'test*.py'
```
