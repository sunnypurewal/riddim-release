# Changelog

## Unreleased

- Added reusable Amplify website preview, promotion, and cleanup workflows with
  thin consuming-repo templates.

## v1.0.0 - 2026-04-28

First framework release for adopting apps.

- Added reusable GitHub Actions workflows for build/deploy, metadata delivery, App Store release submission, and internal self-tests.
- Added shared Fastlane release support, App Store Connect release scripts, marketing copy scripts, runner provisioning scripts, and consumer workflow templates.
- Added adoption, AWS provisioning, App Store Connect provisioning, runner setup, ASO playbook, and budget watcher docs.
- Consumers should pin reusable workflows to `@v1` for the stable v1 contract, never production traffic to `@main`.
- The `v1` tag moves to the latest non-breaking v1.x.y release. Breaking workflow or lane contract changes require a new major tag.
