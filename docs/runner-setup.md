# Self-Hosted macOS Runner Setup

Hosted macOS is the default path. A repo-scoped self-hosted runner is useful
when the GitHub-hosted macOS budget is exhausted or when a local Mac is faster.

## Required Toolchain

- Xcode 26 or newer, selected with `xcode-select`.
- Ruby 3.3, Bundler, and fastlane.
- AWS CLI v2.
- `jq`.
- Python 3 with `PyJWT`, `requests`, and `cryptography`.
- GitHub CLI.
- `ffmpeg` for App Preview encoding.

Install with Homebrew:

```bash
brew update
brew install ruby awscli jq gh python@3 ffmpeg
gem install bundler fastlane
python3 -m pip install --user PyJWT requests cryptography
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

## Register a Repo-Scoped Runner

Set the target repo:

```bash
export GH_REPO=sunnypurewal/justplayit
```

Create a runner directory. Use one directory per repo:

```bash
mkdir -p "$HOME/actions-runners/${GH_REPO##*/}"
cd "$HOME/actions-runners/${GH_REPO##*/}"
```

Download the current macOS ARM64 runner from GitHub's runner settings page for
the repo, or use the URL from the generated setup command:

```bash
curl -o actions-runner-osx-arm64.tar.gz -L "<runner-download-url>"
tar xzf actions-runner-osx-arm64.tar.gz
```

Request a registration token:

```bash
RUNNER_TOKEN=$(gh api \
  --method POST \
  "repos/$GH_REPO/actions/runners/registration-token" \
  --jq .token)
```

Configure the runner:

```bash
./config.sh \
  --url "https://github.com/$GH_REPO" \
  --token "$RUNNER_TOKEN" \
  --name "$(hostname)-${GH_REPO##*/}-mac" \
  --labels "self-hosted,macOS" \
  --unattended
```

Install it as a LaunchAgent:

```bash
./svc.sh install
./svc.sh start
./svc.sh status
```

Update repo variables to use it:

```bash
gh variable set RUNNER_PROFILE --repo "$GH_REPO" --body self-hosted
gh variable set RUNNER_LABELS_MAC \
  --repo "$GH_REPO" \
  --body '["self-hosted","macOS"]'
gh variable set RUNNER_LABELS_LINUX \
  --repo "$GH_REPO" \
  --body '["self-hosted","macOS"]'
```

## Multiple Repos on One Mac

A single Mac can host multiple runner agents. Each repo needs its own runner
directory, service, and registration token. Do not reuse one runner directory
across repos.

Suggested layout:

```text
~/actions-runners/justplayit/
~/actions-runners/bettrack/
~/actions-runners/budscience/
```

## Maintenance

Update Xcode and fastlane deliberately:

```bash
brew upgrade
gem update fastlane
python3 -m pip install --user --upgrade PyJWT requests cryptography
```

If a runner gets stuck:

```bash
cd "$HOME/actions-runners/${GH_REPO##*/}"
./svc.sh stop
./svc.sh start
```
