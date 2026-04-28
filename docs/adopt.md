# Adopting riddim-release in an iOS app

This guide takes an iOS app repo from no release tooling to a first TestFlight
build using `sunnypurewal/riddim-release`. It assumes the app already builds
locally with Xcode and has an App Store Connect app record.

Use production callers pinned to `@v1`. Do not call reusable workflows from
`@main`.

## 1. Prerequisites

You need:

- Apple Developer access for the Riddim team `ZG82TFXU3C`.
- App Store Connect API key access with permission to read apps/builds and
  upload metadata.
- AWS access to the account that stores `appstore/connect-api` and
  `appstore/distribution-cert` in Secrets Manager.
- GitHub admin access on the consuming repo.
- A macOS builder path: GitHub-hosted macOS labels or a repo-scoped
  self-hosted macOS runner.

Install local tools for setup:

```bash
brew install gh awscli jq ruby python@3
gh auth login
aws sts get-caller-identity
```

The App Store Connect lookup snippets below use Python packages that are not in
the standard library. Install them in a disposable setup virtual environment:

```bash
python3 -m venv "$HOME/.venvs/riddim-release-setup"
. "$HOME/.venvs/riddim-release-setup/bin/activate"
python3 -m pip install --upgrade pip PyJWT requests cryptography
```

Set these shell variables before running the examples:

```bash
export OWNER=sunnypurewal
export REPO=justplayit
export GH_REPO="$OWNER/$REPO"
export BUNDLE_ID=com.riddimsoftware.justplayit
export TEAM_ID=ZG82TFXU3C
export SCHEME=JustPlayIt
export XCODEPROJ_PATH=JustPlayIt.xcodeproj
export IOS_WORKDIR=ios
export PRIMARY_LOCALE=en-US
export AWS_RELEASE_ROLE_ARN=arn:aws:iam::<account-id>:role/github-appstore-release
```

## 2. One-Time Provisioning

### Confirm AWS OIDC trust

The release role must trust the GitHub repo subject
`repo:sunnypurewal/<app>:*`. See [aws-provisioning.md](aws-provisioning.md)
for the full trust policy.

```bash
aws iam get-role \
  --role-name "$(basename "$AWS_RELEASE_ROLE_ARN")" \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json | jq .
```

### Confirm the ASC secret exists

```bash
aws secretsmanager get-secret-value \
  --secret-id appstore/connect-api \
  --region us-east-1 \
  --query SecretString \
  --output text | jq 'keys'
```

Expected keys: `key_id`, `issuer_id`, `private_key`.

### Confirm the distribution certificate secret exists

```bash
aws secretsmanager get-secret-value \
  --secret-id appstore/distribution-cert \
  --region us-east-1 \
  --query SecretString \
  --output text | jq 'keys'
```

Expected keys: `p12_base64`, `password`.

### Query `APPLE_APP_ID`

```bash
tmpdir=$(mktemp -d)
aws secretsmanager get-secret-value \
  --secret-id appstore/connect-api \
  --region us-east-1 \
  --query SecretString \
  --output text > "$tmpdir/asc.json"

python3 - <<'PY' "$tmpdir/asc.json" "$tmpdir/AuthKey.p8" "$BUNDLE_ID"
import json
import sys
import time
import jwt
import requests

secret_path, key_path, bundle_id = sys.argv[1:4]
secret = json.load(open(secret_path))
open(key_path, "w").write(secret["private_key"])
now = int(time.time())
token = jwt.encode(
    {"iss": secret["issuer_id"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    secret["private_key"],
    algorithm="ES256",
    headers={"kid": secret["key_id"]},
)
resp = requests.get(
    "https://api.appstoreconnect.apple.com/v1/apps",
    headers={"Authorization": f"Bearer {token}"},
    params={"filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name"},
    timeout=30,
)
resp.raise_for_status()
data = resp.json()["data"]
if not data:
    raise SystemExit(f"No ASC app found for bundle id {bundle_id}")
print(data[0]["id"])
PY
```

Save the printed value:

```bash
export APPLE_APP_ID=<printed-id>
```

### Set GitHub repo variables

```bash
gh variable set APPLE_APP_ID        --repo "$GH_REPO" --body "$APPLE_APP_ID"
gh variable set BUNDLE_ID           --repo "$GH_REPO" --body "$BUNDLE_ID"
gh variable set TEAM_ID             --repo "$GH_REPO" --body "$TEAM_ID"
gh variable set SCHEME              --repo "$GH_REPO" --body "$SCHEME"
gh variable set XCODEPROJ_PATH      --repo "$GH_REPO" --body "$XCODEPROJ_PATH"
gh variable set IOS_WORKDIR         --repo "$GH_REPO" --body "$IOS_WORKDIR"
gh variable set PRIMARY_LOCALE      --repo "$GH_REPO" --body "$PRIMARY_LOCALE"
gh variable set EXTRA_BUNDLE_IDS    --repo "$GH_REPO" --body ""
gh variable set RUNNER_PROFILE      --repo "$GH_REPO" --body hosted
gh variable set RUNNER_LABELS_MAC   --repo "$GH_REPO" --body '["macos-15"]'
gh variable set RUNNER_LABELS_LINUX --repo "$GH_REPO" --body '["ubuntu-latest"]'
```

Runner variables are the only switch between hosted and self-hosted execution.
`RUNNER_PROFILE` records the current mode for humans and automation,
`RUNNER_LABELS_MAC` selects macOS jobs, and `RUNNER_LABELS_LINUX` selects Linux
jobs. The reusable workflows require `runner_labels_mac` and
`runner_labels_linux` as JSON-encoded array strings, and every job uses
`fromJSON(...)` instead of literal runner names. The copied workflow shims
provide hosted fallbacks with `vars.RUNNER_LABELS_MAC || '["macos-15"]'` and
`vars.RUNNER_LABELS_LINUX || '["ubuntu-latest"]'`, so a newly adopted repo can
run before the variables are created.

Use these exact values for the supported profiles:

```bash
# Hosted mode
gh variable set RUNNER_PROFILE      --repo "$GH_REPO" --body hosted
gh variable set RUNNER_LABELS_MAC   --repo "$GH_REPO" --body '["macos-15"]'
gh variable set RUNNER_LABELS_LINUX --repo "$GH_REPO" --body '["ubuntu-latest"]'

# Self-hosted fallback mode
gh variable set RUNNER_PROFILE      --repo "$GH_REPO" --body self-hosted
gh variable set RUNNER_LABELS_MAC   --repo "$GH_REPO" --body '["self-hosted","macOS"]'
gh variable set RUNNER_LABELS_LINUX --repo "$GH_REPO" --body '["self-hosted","macOS"]'
```

If the app has an App Clip or extension, encode extra signing targets as
space-separated `bundle_id=target_name` pairs:

```bash
gh variable set EXTRA_BUNDLE_IDS \
  --repo "$GH_REPO" \
  --body "com.example.app.Clip=AppClipTarget"
```

### Set GitHub secrets

```bash
gh secret set AWS_RELEASE_ROLE_ARN --repo "$GH_REPO" --body "$AWS_RELEASE_ROLE_ARN"
openssl rand -base64 32 | gh secret set KEYCHAIN_PASSWORD --repo "$GH_REPO"
```

Because `riddim-release` is private, reusable workflows need a token that can
read this repo when they check out shared scripts. Store a fine-grained PAT with
read-only `Contents` access to `sunnypurewal/riddim-release` as
`RIDDIM_RELEASE_TOKEN` in each consuming repo:

```bash
gh secret set RIDDIM_RELEASE_TOKEN --repo "$GH_REPO" --body "$RIDDIM_RELEASE_TOKEN"
```

If the repo already has `RUNNER_BUDGET_PAT` with `repo` access for the budget
watcher, the workflows can use that as a fallback, but a narrower
`RIDDIM_RELEASE_TOKEN` is preferred.

### Register a self-hosted runner

Hosted macOS works for the default path. For budget fallback or faster local
builds, register a repo-scoped runner by following
[runner-setup.md](runner-setup.md).

### Create the `app-store-release` environment

```bash
gh api --method PUT \
  "repos/$GH_REPO/environments/app-store-release" \
  --field wait_timer=0
```

Add required reviewers in GitHub UI:

`Settings -> Environments -> app-store-release -> Required reviewers`.

## 3. Repo Scaffolding

From the consuming repo root:

```bash
export RIDDIM_RELEASE_REF=v1

mkdir -p .github/workflows "$IOS_WORKDIR/fastlane"
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/workflows/build-deploy.shim.yml" \
  -o .github/workflows/build-deploy.yml
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/workflows/release-app-store.shim.yml" \
  -o .github/workflows/release-app-store.yml
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/workflows/deliver-metadata.shim.yml" \
  -o .github/workflows/deliver-metadata.yml
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/workflows/budget-watcher.yml" \
  -o .github/workflows/budget-watcher.yml
curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/workflows/collect-asc-analytics.shim.yml" \
  -o .github/workflows/collect-asc-analytics.yml
```

Copy the fastlane scaffold:

```bash
for file in Fastfile Appfile.erb Deliverfile.erb Snapfile.erb Pluginfile Gemfile; do
  curl -fsSL "https://raw.githubusercontent.com/sunnypurewal/riddim-release/$RIDDIM_RELEASE_REF/templates/fastlane/$file" \
    -o "$IOS_WORKDIR/fastlane/$file"
done
```

Use `RIDDIM_RELEASE_REF=v1` for production adoption after the v1 tag is cut. For
pre-v1 fixture validation, set it to the reviewed commit SHA that contains the
template directory.

Render the ERB placeholders:

```bash
ruby -rerb -e 'bundle_id=ENV.fetch("BUNDLE_ID"); team_id=ENV.fetch("TEAM_ID"); print ERB.new(File.read(ARGV[0])).result(binding)' \
  "$IOS_WORKDIR/fastlane/Appfile.erb" > "$IOS_WORKDIR/fastlane/Appfile"
ruby -rerb -e 'bundle_id=ENV.fetch("BUNDLE_ID"); team_id=ENV.fetch("TEAM_ID"); print ERB.new(File.read(ARGV[0])).result(binding)' \
  "$IOS_WORKDIR/fastlane/Deliverfile.erb" > "$IOS_WORKDIR/fastlane/Deliverfile"
ruby -rerb -e 'scheme=ENV.fetch("SCHEME"); primary_locale=ENV.fetch("PRIMARY_LOCALE"); print ERB.new(File.read(ARGV[0])).result(binding)' \
  "$IOS_WORKDIR/fastlane/Snapfile.erb" > "$IOS_WORKDIR/fastlane/Snapfile"
rm "$IOS_WORKDIR/fastlane/"*.erb
```

Confirm the Fastfile imports the shared lanes:

```ruby
import_from_git(
  url:    "https://github.com/sunnypurewal/riddim-release.git",
  branch: "v1",
  path:   "fastlane/Fastfile"
)
```

Populate metadata and media folders:

```bash
mkdir -p \
  "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE" \
  "$IOS_WORKDIR/fastlane/screenshots/$PRIMARY_LOCALE" \
  "$IOS_WORKDIR/fastlane/app-previews/$PRIMARY_LOCALE"

printf 'App Name\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/name.txt"
printf 'Short subtitle\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/subtitle.txt"
printf 'keyword1,keyword2\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/keywords.txt"
printf 'Support URL\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/support_url.txt"
printf 'Marketing URL\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/marketing_url.txt"
printf 'Privacy URL\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/privacy_url.txt"
printf 'Initial release notes.\n' > "$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/release_notes.txt"
```

Capture screenshots into
`$IOS_WORKDIR/fastlane/screenshots/$PRIMARY_LOCALE/`. If the app has an App
Preview test target, see [aso-playbook.md](aso-playbook.md) for the preview
recording script.

Commit the scaffold:

```bash
git add .github "$IOS_WORKDIR/fastlane"
git commit -m "Adopt riddim-release"
git push
```

### Sample PleasePlay release config

Use this as a completed value set when reviewing a new app's variables:

```yaml
repo: sunnypurewal/justplayit
apple_app_id: "<query from ASC>"
bundle_id: com.riddimsoftware.justplayit
team_id: ZG82TFXU3C
scheme: JustPlayIt
xcodeproj_path: JustPlayIt.xcodeproj
ios_workdir: ios
primary_locale: en-US
extra_bundle_ids: ""
runner_labels_mac: '["macos-15"]'
runner_labels_linux: '["ubuntu-latest"]'
runner_profile: hosted
approval_environment: app-store-release
aws_release_role_arn: arn:aws:iam::<account-id>:role/github-appstore-release
```

## 4. First Build

Run a dry run first:

```bash
gh workflow run build-deploy.yml \
  --repo "$GH_REPO" \
  -f bump=patch \
  -f dry_run=true
gh run list --repo "$GH_REPO" --workflow build-deploy.yml --limit 3
```

Open the latest run and confirm the jobs complete:

```bash
gh run watch --repo "$GH_REPO" "$(gh run list --repo "$GH_REPO" --workflow build-deploy.yml --json databaseId --jq '.[0].databaseId')"
```

Run the real build:

```bash
gh workflow run build-deploy.yml \
  --repo "$GH_REPO" \
  -f bump=patch \
  -f dry_run=false
```

After the run finishes, confirm TestFlight has a new valid build and a draft
GitHub Release exists:

```bash
gh release list --repo "$GH_REPO" --limit 5
```

Install the TestFlight build on a device and smoke-test the release candidate.

## 5. First ASC Submission

When QA accepts the TestFlight build, publish the draft GitHub Release:

```bash
gh release edit v<version> --repo "$GH_REPO" --draft=false
```

Publishing the release triggers `.github/workflows/release-app-store.yml`.
Watch it:

```bash
gh run list --repo "$GH_REPO" --workflow release-app-store.yml --limit 3
gh run watch --repo "$GH_REPO" "$(gh run list --repo "$GH_REPO" --workflow release-app-store.yml --json databaseId --jq '.[0].databaseId')"
```

The `approve-release` job pauses on the `app-store-release` environment.
Approve it in GitHub after checking the version, build number, tag, upload
time, and release notes.

The submit job uploads metadata/screenshots, attaches the matching TestFlight
build, submits for App Store review, sets `automatic_release:false`, and enables
phased release.

## 6. Notifications (optional)

`build-deploy.yml` posts a "new build ready for QA" Slack message immediately
after the draft GitHub Release is created. This is the operator-UX equivalent
of the GitHub "Approve deployment" notification that fires when an
Environment has required reviewers — useful for repos that cannot attach
required reviewers to `app-store-release` (e.g. private repo on Free plan).

### Mint an Incoming Webhook

1. Slack → your workspace → *Apps* → *Incoming WebHooks*.
2. Pick the channel that should receive build notifications (e.g.
   `#releases`).
3. Copy the webhook URL.

### Set the secret

```bash
gh secret set SLACK_RELEASES_WEBHOOK --repo "$GH_REPO" --body "https://hooks.slack.com/services/..."
```

Make sure the consuming repo's shim forwards secrets — `secrets: inherit` in
`.github/workflows/build-deploy.yml` is the simplest form. If the shim names
secrets explicitly, add `SLACK_RELEASES_WEBHOOK: ${{ secrets.SLACK_RELEASES_WEBHOOK }}`.

When the webhook secret is **unset**, the notify step logs a skip line and
the workflow continues — no setup is required to opt out.

The message contains the repo, version, build number, a link to the draft
GitHub Release, a link to the app's TestFlight page in App Store Connect,
and a reminder that publishing the draft Release fires
`release-app-store.yml`.

## Related Docs

- [runner-setup.md](runner-setup.md)
- [aws-provisioning.md](aws-provisioning.md)
- [asc-provisioning.md](asc-provisioning.md)
- [budget-watcher.md](budget-watcher.md)
- [aso-playbook.md](aso-playbook.md)
