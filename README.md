# riddim-release

Shareable App Store release framework for the riddimsoftware org. Reusable GitHub Actions workflows + a shared fastlane Fastfile + ASC release scripts that consuming iOS app repos wire in via short shim workflows and a 5-line `import_from_git` Fastfile.

Sister to [`evidence`](https://github.com/sunnypurewal/evidence) and [`autopilot`](https://github.com/sunnypurewal/autopilot). PleasePlay is the first consumer; bettrack and BudScience adopt next; epac retrofits onto it once the framework is stable.

## Status

**Bootstrapping.** Not yet usable. Track progress in the RIDDIM Jira project — Epic 1 ("Bootstrap riddim-release repo"). The framework will be tagged `v1` once Epic 1 closes; consumers should pin to `@v1` from then on.

## What it provides

- **3 reusable GitHub Actions workflows** (`build-deploy.yml`, `release-app-store.yml`, `deliver-metadata.yml`) callable via `uses: sunnypurewal/riddim-release/.github/workflows/<name>.yml@v1`.
- **Shared fastlane lanes** (`deploy`, `deliver`) parameterized by lane options, consumed via `import_from_git`.
- **ASC release scripts** (`compute_next_version.py`, `find_qualifying_build.py`, `generate_release_notes.py`, `verify_evidence.py`) that talk to the App Store Connect API.
- **ASC analytics artifact contract** (`docs/analytics-artifact.md`) for raw and enriched App Store Connect report data.
- **Marketing scripts** (`aso-baseline-audit.sh`, `record-app-preview.sh`).
- **Templates** for adopting apps to copy into their own repo (workflow shims, fastlane scaffold, CODEOWNERS, PR template).
- **Budget-aware runner selection** — workflows pick GitHub-hosted vs self-hosted macOS runners based on each consuming repo's `RUNNER_LABELS_MAC` / `RUNNER_LABELS_LINUX` repo variables, flipped by a scheduled budget watcher when the user-account Actions budget exhausts.

## How a consuming app uses it

See `docs/adopt.md` for the full onboarding guide. Short version: each app repo gets 4 small workflow shims, a fastlane scaffold, per-locale metadata files, and screenshots — then `gh workflow run build-deploy.yml` cuts a TestFlight build, a published GitHub Release submits to ASC, and edits to `ios/fastlane/metadata/**` push to ASC immediately.

## Layout

```
.github/workflows/   reusable workflows (workflow_call)
fastlane/            shared Fastfile + helpers consumed via import_from_git
scripts/release/     ASC API clients
scripts/analytics/   ASC analytics artifact fixture tests
scripts/marketing/   ASO + App Preview tooling
scripts/runner/      runner-side bash helpers (keychain, AWS secret fetch)
templates/           files an adopting app copies into its own repo
docs/                onboarding + ops guides
```

## License

MIT — see [LICENSE](LICENSE).
