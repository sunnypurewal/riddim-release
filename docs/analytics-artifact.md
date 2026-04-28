# App Store Connect Analytics Artifact Contract

This contract defines the repo-owned output shape for App Store Connect
analytics collection. It is intentionally file-based so consuming app repos can
review, diff, reprocess, and cite Apple data without depending on a separate
warehouse.

Collectors write raw Apple files exactly once. Normalizers and evaluators write
sidecars next to those raw files, and can be rerun without changing the source
downloads.

## Artifact Root

Each consuming app stores analytics artifacts under:

```text
docs/analytics/app-store-connect/<app-slug>/<window-start>_<window-end>/
```

For a single daily collection, use the same date for both ends:

```text
docs/analytics/app-store-connect/pleaseplay/2026-04-27_2026-04-27/
```

For a campaign or benchmark window, use inclusive dates:

```text
docs/analytics/app-store-connect/pleaseplay/2026-04-01_2026-04-30/
```

The artifact root owns these files and directories:

```text
manifest.json
report-catalog.json
summary.md
raw/
  analytics/<report-type>/<granularity>/<report-date>/<instance-id>/<segment-id>.txt.gz
  sales/<frequency>/<report-date>/<report-type>-<report-subtype>.txt.gz
  finance/<region>/<fiscal-period>/<report-type>.txt.gz
normalized/
  analytics/<report-type>/<granularity>/<report-date>.jsonl
  sales/<frequency>/<report-date>.jsonl
  finance/<region>/<fiscal-period>.jsonl
schema/
  analytics/<report-type>/<granularity>.schema.json
  sales/<report-type>/<report-subtype>.schema.json
  finance/<region>/<report-type>.schema.json
evaluation/
  <jira-key-or-campaign-key>.md
```

`raw/` contains Apple-delivered files. `normalized/`, `schema/`, `summary.md`,
and `evaluation/` are sidecars. If a sidecar needs to change, regenerate the
sidecar and update `manifest.json`; do not rewrite raw files.

## Raw File Immutability

Raw files are immutable after a successful download. The collector must check
the existing file's checksum before writing:

- If the path does not exist, write the downloaded bytes and record the checksum.
- If the path exists and the checksum matches, reuse it and mark the segment
  `unchanged`.
- If the path exists and the checksum differs, fail the run before writing.

Apple often serves report data as compressed `.txt.gz` files. Store those bytes
unchanged. Do not decompress, sort, trim, rename columns, or normalize line
endings inside `raw/`.

## Manifest

Every attempted collection writes or updates `manifest.json`. The manifest is
the audit log for what the command tried, what Apple returned, and what the repo
stored.

Required top-level fields:

- `artifact_version`: Contract version, starting at `1`.
- `tool_version`: The collector or normalizer version that wrote the manifest.
- `generated_at`: UTC ISO-8601 timestamp.
- `app`: App identifiers, including `app_id`, `bundle_id`, optional
  `provider_id`, optional `team_id`, and `app_slug`.
- `window`: Inclusive `start_date`, `end_date`, and `timezone`.
- `business_context`: Optional campaign and release context.
- `reports`: Array of report attempts.
- `completeness`: Rollup status and caveats.

Each `reports[]` entry must include:

- `artifact_id`: Stable id for this report attempt within the artifact.
- `family`: `analytics`, `sales`, or `finance`.
- `category`: Apple report category when available.
- `type`: Apple report type.
- `subtype`: Apple subtype when available, otherwise `null`.
- `granularity`: Apple report granularity or frequency.
- `requested_date` or `requested_window`.
- `request_id`: Analytics Reports request id when available.
- `report_id`: Analytics Reports report id when available.
- `instance_id`: Generated report instance id when available.
- `segment_id`: Segment id when the row describes one segment.
- `download_url_source`: API endpoint or relationship used to obtain the URL.
- `raw_path`: Path to the immutable source file, relative to the repo root.
- `downloaded_at`: UTC ISO-8601 timestamp, or `null` when no file was available.
- `checksum_sha256`: SHA-256 of the raw bytes, or `null`.
- `byte_count`: Raw byte count, or `null`.
- `row_count`: Parsed row count when a sidecar exists, otherwise `null`.
- `status`: One of the manifest statuses below.
- `status_reason`: Human-readable explanation for non-success statuses.
- `normalized_path`: Sidecar path, or `null`.
- `schema_path`: Schema snapshot path, or `null`.

Valid report statuses:

- `planned`: Dry-run only; the command would touch this report.
- `downloaded`: A new raw segment was written.
- `unchanged`: A matching raw segment already existed.
- `normalized`: A sidecar was generated from an existing raw file.
- `empty`: Apple returned a valid report with no rows.
- `delayed`: Apple has not generated the report yet.
- `thresholded`: Apple withheld rows because of privacy thresholds.
- `permission_blocked`: The key or user lacks access to the report family.
- `unavailable`: Apple reports that this report is not available for the app.
- `missing_segment`: At least one expected segment was absent.
- `error`: The collector received an unrecoverable response.

Do not mark a report instance complete if any expected segment is missing.
Use `missing_segment` on the affected report entry and set
`completeness.status` to `incomplete`.

## Business Context

Business context fields are optional, but when present they should be copied
into normalized rows and evaluation outputs:

- `jira_keys`: Campaign, benchmark, or release ticket keys.
- `release_tag`: Git tag or GitHub Release tag.
- `app_version`: App Store marketing version.
- `build_number`: Build number used for the analyzed window.
- `locales`: Locales included in metadata or campaign work.
- `territories`: ASC territory codes in scope.
- `source_types`: Apple source type values, such as App Store Browse or Search.
- `source_info`: Apple source info values when available.
- `marketing_channels`: Repo-defined channel labels.
- `notes`: Free-form operator notes.

If a collector cannot determine context automatically, leave the field absent or
empty. Do not invent campaign mappings.

## Report Catalog

`report-catalog.json` tells collectors which report families are enabled for a
consuming app and where artifacts should be written. It is committed to the app
repo and contains no secrets.

Required fields:

- `catalog_version`: Config format version, starting at `1`.
- `app.app_id`: App Store Connect app id.
- `app.bundle_id`: Bundle id.
- `app.app_slug`: Stable lowercase slug used in artifact paths.
- `output.root`: Default artifact root.
- `collection.window`: Backfill or collection window defaults.
- `collection.retention_days`: How long generated artifacts should be retained.
- `business_context_mappings`: Optional Jira, release, locale, territory, and
  marketing-channel mappings.
- `families.analytics_reports.enabled`
- `families.sales_trends.enabled`
- `families.finance.enabled`

Each enabled report family lists the report types, granularities or frequencies,
and any family-specific required parameters. Sales and Finance entries must
validate vendor number, region, fiscal period, and report subtype before network
calls.

See [fixtures/report-catalog.example.json](analytics/fixtures/report-catalog.example.json)
for a complete fixture.

## Normalized Sidecars

Normalizers read `raw/` files and write `normalized/` sidecars. Sidecars should
prefer JSON Lines for lossless row records:

```json
{
  "_artifact_id": "analytics-app-store-discovery-daily-2026-04-27-seg-001",
  "_source_file": "docs/analytics/app-store-connect/pleaseplay/.../seg-001.txt.gz",
  "_checksum": "sha256:...",
  "_report_family": "analytics",
  "_granularity": "daily",
  "_downloaded_at": "2026-04-28T02:13:00Z",
  "_app_id": "1234567890",
  "_bundle_id": "com.riddimsoftware.pleaseplay",
  "Impressions": "42",
  "Product Page Views": "12"
}
```

Every normalized row must preserve all Apple source columns exactly as observed.
Additional fields must be namespaced with a leading underscore so future Apple
columns cannot collide with enrichment fields.

## Schema Snapshots

Schema snapshots live under `schema/` and are generated from observed report
headers and parsed values. The first collector stories do not need to define
every possible Apple column manually. Later collector and normalizer work should
update schema snapshots when source headers change.

At minimum, each schema snapshot records:

- Source file paths and checksums used to infer the schema.
- Observed column names in source order.
- Inferred primitive type per column when available.
- Tool version and generated timestamp.
- Unknown or newly observed columns.

## Summary and Evaluations

`summary.md` is a human-readable overview of the artifact. It should include:

- App and date window.
- Report families requested and included.
- Row counts and raw file counts by family.
- Missing, delayed, thresholded, or permission-blocked reports.
- Links to `manifest.json`, raw paths, normalized paths, and schema snapshots.

`evaluation/*.md` files are optional business outputs for campaign and benchmark
reviews. They must cite the manifest and sidecars used for each metric.

## Apple Availability Caveats

Apple reports can be delayed, unavailable for an app, withheld because of
privacy thresholds, or blocked by API key permissions. Missing rows are not zero
activity unless Apple explicitly returns a valid report with zero rows.

Collectors and evaluators must distinguish:

- `empty`: Apple returned a valid report with no rows.
- `delayed`: The generated report is not available yet.
- `thresholded`: Apple withheld data due to privacy thresholds.
- `permission_blocked`: Credentials cannot access the report.
- `unavailable`: The app or account does not have that report.
- `missing_segment`: A multi-segment report is incomplete.

Evaluations must treat every non-empty missing-data status as
`insufficient_data`, not as a zero result.

## Sales And Finance Access

Sales and Trends collection uses the App Store Connect Sales and Trends report
endpoint. The catalog must provide a vendor number plus frequency, report date,
report type, subtype, and report version. These reports are useful for download,
sales, proceeds proxy, territory, and product-type dimensions, but they are not
financial settlement records.

Finance collection uses the Finance report endpoint. The catalog must provide a
vendor number, region code, fiscal period, and report type. Finance access is
role- and account-dependent; many valid App Store Connect API keys can read app
or sales data but cannot read finance reports. Collectors must record those
responses as `permission_blocked` or `unavailable` in `manifest.json` and keep
collecting unrelated report families.

## Fixtures

This repo includes fixture files for documentation and tests:

- [fixtures/report-catalog.example.json](analytics/fixtures/report-catalog.example.json)
- [fixtures/manifest.example.json](analytics/fixtures/manifest.example.json)

The fixtures are intentionally small, but they exercise the contract shape used
by collector, normalizer, evaluator, and workflow stories in RIDDIM-57.
