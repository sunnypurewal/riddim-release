# Website Releases

`riddim-release` supports static website releases through reusable GitHub
Actions workflows. Consuming repos keep small workflow shims and use AWS
Amplify manual deployments for preview and production hosting.

## Flow

1. Pull requests from branches in the consuming repository deploy to an Amplify
   preview branch named `pr-<number>`.
2. The preview workflow uploads `site.zip` and `website-preview-manifest.json`
   as a GitHub Actions artifact.
3. When the PR is merged, the promote workflow verifies that the previewed
   commit is an ancestor of `main`.
4. The production job pauses on the `website-production` GitHub Environment.
5. After approval, the workflow deploys the exact preview artifact to the
   Amplify `main` branch and deletes the preview branch.

Fork PRs are intentionally skipped by the template because preview deployment
requires AWS credentials.

## Required repo variables

- `AMPLIFY_APP_ID`
- `AWS_REGION`
- `AWS_WEBSITE_PREVIEW_ROLE_ARN`
- `AWS_WEBSITE_PRODUCTION_ROLE_ARN`
- `RIDDIM_RELEASE_REF`, default `v1`

## Required GitHub environments

- `website-preview`: no required reviewers.
- `website-production`: required reviewers enabled.

## AWS role shape

The preview role should trust the consuming repository's
`website-preview` environment and allow Amplify create/deploy/delete for
`pr-*` branches. The production role should trust `website-production` and allow
manual deployment only to the Amplify `main` branch.
