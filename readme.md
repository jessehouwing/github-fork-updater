This repository has been created to facilitate updating your forked repositories with review actions. Especially helpful when having a separate organization for all your forked GitHub Actions (as you should for security reasons). Read more on that topic [here](https://devopsjournal.io/blog/2021/02/06/GitHub-Actions-Forking-Repositories).

Process:
* Fork this repository to the organization / account you want to update your forks in.
* Configure it using the steps below.
* On a schedule, the workflow will run checking all the repositories in the organization / account
* If the repository is a fork, it will be checked for incoming updates
* If there are updates, an issue in the `GitHubForkUpdater` repository will be created.
* Validate the incoming changes using the link in the issue
* If you add the label `update-fork` to the issue, your fork will be updated
* And the issue will be closed

# Steps
Watch the demo video here:  

[![Watch the demo video here](video-image.png)](https://youtu.be/Jj033ffS1YQ)


Or follow these steps:
1. Fork this repository to your own organization.
1. Enable issue in the forked repository (issues are disabled on the fork by default, since you'd want any issues to be created on the parent repo, not the forked one).
1. Run the `init-workflow.yml` workflow once to create the labels this tool uses (see below).
1. Enable the workflow `check-workflow.yml` and allow the schedule to run (GitHub security feature).
1. Either add a repository secret named `PAT_GITHUB` containing a GitHub Personal Access Token with these scopes: `public_repo, read:org, read:user, repo:status, repo_deployment, issues:write` (see below on why) or use a GitHub App with `GH_AUTOMATION_ID` and `GH_AUTOMATION_PRIVATE_KEY`. Read more info on the differences [here](https://devopsjournal.io/blog/2022/01/03/GitHub-Tokens).
1. Add configuration for using a GitHub App or a PAT with the Actions variable in your repo called `USE_GITHUB_APP`, value is true or false.
1. Trigger the `check-workflow.yml` workflow manually for the first run or wait for the schedule to run.
1. Check the new issues on the forked repo for instructions on updating your forks.
1. Verify incoming changes and label the issue if you want to update the fork.
1. Use the default GitHub Notification messages to keep all your forks up to date or use the `Send notification` variable to tag a team when a new issue is created. Variables are `SEND_NOTIFICATION` and `NOTIFICATION_TEAM`.
1. Enjoy!

# Schedule runs
The scheduled runs are planned at weekdays, at 7 AM.

# init-workflow.yml
Run this workflow manually once after setting up the repository. It creates the labels the tool uses, with a description explaining what each one means. Running it again is safe: existing labels are updated to the expected colour and description rather than duplicated.

| Label | Meaning |
|---|---|
| `update-available` | The upstream repository has changes that are not in this fork or mirror yet |
| `parent-archived` | The upstream repository has been archived, consider finding an alternative |
| `update-fork` | Add this label to approve the recorded versions and sync the fork or mirror |

The labels are defined in [labels.ps1](labels.ps1), which is also what the check and update workflows apply, so the two cannot drift apart.

# check-workflow.yml
The check-workflow will iterate all repositories in the same organization (or user) and find the ones that are forks of another repository (called parent repository). For the forks it will check if there are updates available in the parent repository and if so, create new issues in this repository (GitHubForkUpdater) with a link to verify those changes. 

## Security
This workflow will run using the default `GITHUB_TOKEN`, which is enough to iterate through your own **public** repositories and check the public parents for incoming changes.

##### Note: This workflow can be triggered manually or will run on a schedule.

# update-workflow.yml
The issues will have links for you to review all incoming changes from the parent repository. Please go through all those changes and review if you want to pull in the changes. Especially for GitHub Actions you use, it is very important to review the changes: otherwise you are updating code from the internet that will run in your own workflows 😱. Read more info [here](https://devopsjournal.io/blog/2021/12/11/GitHub-Actions-Maturity-Levels).

After reviewing the changes in the parent repository, you can decide to pull in those changes into your own fork. Adding the label `update-fork` on the issues will trigger the `update-workflow` to pull in the incoming changes. The issue will be updated when the workflow starts and be closed when the workflow has completed successfully. If there are merge conflicts, the workflow will fail and add a message in the issue.

Note: currently only the `default branch` will be updated, together with all Tags.

# Approving a specific version
Every issue records exactly which upstream versions were submitted for approval: the default branch and its commit SHA, and for mirrors also the tags and the releases that would be synced. This is shown in a **Versions submitted for approval** section on the issue, and stored in a hidden marker in the issue body.

When you add the `update-fork` label, the upstream is checked again against those recorded versions. If anything moved in the meantime, the update is **not** applied. Instead the workflow:

1. Posts a comment listing what changed (new commits on the default branch, added or moved tags, new releases).
1. Removes the `update-fork` label.
1. Updates the issue with the new versions.

You then review the new changes and re-apply the label to approve them. The scheduled check does the same thing: when it finds an open issue whose upstream has moved on, it refreshes the issue and drops the label, so an approval that was given earlier can never be applied to code that was not reviewed.

This matters most for mirrors, where a floating tag such as `v1` can be repointed to a different commit upstream without the default branch changing at all. Tags are compared by name **and** commit SHA, so a moved tag invalidates the approval.

## Security 
To be able to push the incoming changes into your fork we need a GitHub Access Token used in this workflow with the name `PAT_GITHUB`. This token needs to have the following scopes: `public_repo*, read:org, read:user, repo:status*, repo_deployment*, workflow, actions: write, content: write, issues:write`. 
`*` These scopes are set by default when the `workflows` scope is set

There are two ways to create this token:
1. Use a GitHub App and get the token from it (Recommended), more info on these tokens [here](https://devopsjournal.io/blog/2022/01/03/GitHub-Tokens).
1. Use a Personal Access Token (has to much rights and is a security risk)!

You can read more information about this in this [blogpost](https://devopsjournal.io/blog/2022/01/03/GitHub-Tokens).

### GitHub App security scopes
To use a GitHub App, create a repository variable called `use_github_app` and set its value to `true`. Then create an app with the following security scopes and install it at the org level with the repositories you want to handle updates for.

** Scopes **
- Actions: read & write (needed to be able to update files in the .github/workflows folder)
- Contents: read & write (needed to be able to update the repo contents)
- Issues: read & write (needed to create and close the issues to be able to notify you of updates)
- Workflows: read & write (needed to be able to update workflows)
- Metadata: read only (default setting)
- Custom properties: read only (needed to read the per repository sync configuration)

# GHE.com / GitHub Enterprise Server support
The updater can keep repositories on a [GHE.com](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency) tenant (or a GitHub Enterprise Server instance) in sync with upstream repositories on public GitHub. This needs two tokens: one to **read** from public GitHub and one to **write** to your enterprise host.

| Parameter | Purpose |
|---|---|
| `-targetServerUrl` | The host that holds your repositories, for example `https://contoso.ghe.com`. Defaults to `https://github.com` |
| `-targetToken` | Token with write access on `targetServerUrl` |
| `-sourceToken` | Token with read access on public GitHub |
| `-PAT` | Legacy single token. Used for both sides when the two above are not supplied |

The API endpoints are derived from the server url automatically: `https://contoso.ghe.com` resolves to `https://api.contoso.ghe.com`, and a GitHub Enterprise Server host resolves to `https://<host>/api/v3`. The workflows derive this with the same code the scripts use, so there is only one place to configure it.

Configure this with the following repository variables and secrets. When the workflows run on the tenant itself, `TARGET_SERVER_URL` can be left unset because it defaults to the server the workflow is running on.

| Setting | Kind | Purpose |
|---|---|---|
| `TARGET_SERVER_URL` | variable | The host that holds your repositories, for example `https://contoso.ghe.com`. Defaults to the server the workflow runs on |
| `TARGET_ORG` | variable | The organization to scan. Defaults to the owner of this repository |
| `USE_GITHUB_APP` | variable | Set to `true` to mint the target token from a GitHub App |
| `GH_AUTOMATION_ID` / `GH_AUTOMATION_PRIVATE_KEY` | secret | The GitHub App on the target host |
| `USE_PUBLIC_GITHUB_APP` | variable | Set to `true` to mint the public GitHub token from a separate GitHub App |
| `GH_PUBLIC_APP_ID` / `GH_PUBLIC_APP_PRIVATE_KEY` | secret | The GitHub App on public GitHub |
| `PUBLIC_GITHUB_ORG` | variable | The organization the public GitHub App is installed on |
| `PAT_GITHUB` | secret | Fallback token for the target host when no App is configured |
| `PAT_GITHUB_PUBLIC` | secret | Fallback token for public GitHub. When unset, the target token is used for both |

The GitHub App token is always requested against the API of the host the App lives on, and is scoped to the whole organization rather than to this repository, because the updater reads and writes other repositories.

The source credentials are only used when the target is a different host. If `TARGET_SERVER_URL` resolves to public GitHub, the source and target are the same host, so no second token is minted and the target token is used for both. On a GHE.com or GitHub Enterprise Server target the workflow mints a separate token for public GitHub, falling back to `PAT_GITHUB_PUBLIC` and then to the target token when neither is configured.

# Mirrors
Next to real forks, the updater also handles **mirror** repositories that have no fork relationship with their upstream. The upstream is resolved in this order:

1. The `upstream-url` custom property on the repository, for example `https://github.com/actions/checkout`.
1. The fork parent, when the repository is a real fork.
1. The naming convention `org_repo`, splitting on the **first** underscore. So `actions_checkout` maps to `actions/checkout` and `actions_setup_node` maps to `actions/setup_node`.

Repositories that match none of these are skipped.

When looking up an upstream, the enterprise host is queried first and public GitHub is only used as a fallback, so an internally mirrored dependency wins over the public one.

## Configuring the sync with custom properties
Set these [custom properties](https://docs.github.com/en/organizations/managing-organization-settings/managing-custom-properties-for-repositories-in-your-organization) on the mirror repository to control what gets synced. All of them are optional.

| Property | Values | Default | Description |
|---|---|---|---|
| `upstream-url` | a repository url | _unset_ | Overrides the `org_repo` naming convention |
| `sync-mode` | `approve`, `auto` | `approve` | `approve` creates an issue and waits for the `update-fork` label, `auto` syncs immediately |
| `sync-branches` | `default`, `all`, `none` | `default` | Which branches to push to the mirror |
| `sync-floating-tags` | `true`, `false` | `true` | Whether mutable tags like `v1`, `v1.0` and `latest` are force updated |
| `sync-releases` | `none`, `all`, `immutable` | `none` | Which upstream releases are recreated on the target |
| `sync-release-assets` | `true`, `false` | `false` | Whether the release attachments are copied along with the release |
| `verify-upstream-attestations` | `true`, `false` | `false` | Verify the upstream artifact attestations before recreating a release |

Mirrors are synced with a bare clone of the upstream that is pushed to the mirror. Tags are pushed one by one, so a tag that is protected by an immutable release on the target does not block the rest of the sync.

## Immutable releases
With `sync-releases: immutable` only releases that GitHub reports as immutable are recreated on the mirror, with `sync-releases: all` every published (non draft) release is recreated. Releases are created as published, which makes them immutable when [immutable releases](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases) are enabled on the target.

This applies to real forks as well as mirrors. Merging a fork pushes the branch and its tags, but releases are separate objects that only exist through the API, so they are never copied unless you set `sync-releases`. The approval table on the issue says so explicitly, so it is clear whether releases are part of what you are approving.

## Release assets
Set `sync-release-assets: true` to copy the release attachments as well. The release is then created as a draft, the assets are uploaded, and only after that the release is published. That ordering matters: publishing is what seals an immutable release, so a release published before its assets are uploaded would be sealed without them.

## Attestations
Artifact attestations are **not** copied to the mirror, and they cannot be. They are stored per repository keyed by the artifact digest, and the signing certificate identifies the upstream repository and workflow. Re-uploading a bundle to the mirror would not verify, and re-signing it on the mirror would assert your own provenance over code you did not build.

Instead, set `verify-upstream-attestations: true` to verify at the boundary. Before a release is recreated, the assets are downloaded and checked with `gh attestation verify --repo <upstream>` against the upstream repository. A release is skipped when verification fails or when no attestation is present, so this fails closed. It needs the GitHub CLI on the runner and network access to public GitHub.


