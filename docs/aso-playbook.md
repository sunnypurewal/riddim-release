# ASO Playbook

This playbook keeps App Store metadata, screenshots, and preview videos fresh
between binary releases.

## Cadence

- Monthly: run a baseline audit and review ratings, recent reviews, keywords,
  and competitor notes.
- Quarterly: refresh screenshots when UI or positioning changes.
- On major UI changes: record a new App Preview.
- On every metadata PR: include a `Release-Note:` line only when the change is
  user-facing for the next binary release.

## Metadata-Only PR Flow

1. Create a branch in the consuming app repo.
2. Edit files under `ios/fastlane/metadata/<locale>/`.
3. Open a PR with screenshots of the App Store listing preview when relevant.
4. Merge to `main`.
5. The `deliver-metadata.yml` shim fires within about 60 seconds.
6. App Store Connect reflects text metadata after fastlane deliver completes.

Example:

```bash
git switch -c marketing/update-keywords
printf 'music discovery,playlist,ambient music\n' > ios/fastlane/metadata/en-US/keywords.txt
git add ios/fastlane/metadata/en-US/keywords.txt
git commit -m "Update App Store keywords"
git push -u origin marketing/update-keywords
gh pr create --title "Update App Store keywords" --body "Release-Note: internal"
```

## Baseline Audit

Run from the consuming repo root after `fetch_asc_secret.sh` has populated ASC
environment variables:

```bash
export ASC_APP_ID="$APPLE_APP_ID"
export PRIMARY_LOCALE=en-US
export IOS_WORKDIR=ios
export EVIDENCE_OUTPUT_DIR=docs/marketing
scripts/marketing/aso-baseline-audit.sh
```

The report path is:

```text
docs/marketing/growth-metrics-YYYY-MM.md
```

The report includes ratings, recent reviews, current keywords, and placeholders
for analytics not exposed by the App Store Connect API.

## App Preview Recording

The shared script expects an app-specific UI test that drives the preview flow.

```bash
export SCHEME=JustPlayIt
export BUNDLE_ID=com.riddimsoftware.justplayit
export UITEST_TARGET='JustPlayItUITests/AppPreviewRecordingTests/testAppPreviewSequence'
export DEVICE_NAME='iPhone 17 Pro Max'
export IOS_WORKDIR=ios
export PRIMARY_LOCALE=en-US
export OUTPUT_DIR=docs/marketing/preview
scripts/marketing/record-app-preview.sh
```

Output paths:

```text
docs/marketing/preview/app-preview-final.mp4
ios/fastlane/app-previews/en-US/IPHONE_67_app-preview.mp4
```

If the consuming repo has `scripts/evidence/run-evidence.sh`, the preview script
delegates encoding to it. Otherwise it falls back to inline `ffmpeg` commands.

Do not commit failed recording attempts or large intermediate videos.
