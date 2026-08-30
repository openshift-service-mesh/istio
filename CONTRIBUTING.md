# Contribution guidelines

> **This is the Red Hat midstream fork of [istio/istio](https://github.com/istio/istio).**
> See [docs/upstream.md](docs/upstream.md) for the full upstream contribution workflow,
> branch mapping, sync process, and guidance on whether a change belongs here or upstream.

So you want to hack on Istio? Please refer to Istio's overall
[contribution guidelines](https://github.com/istio/community/blob/master/CONTRIBUTING.md)
for upstream contribution. For OSSM-specific changes in this midstream repository, follow
the requirements below.

## OSSM-Specific Requirements

### Pull Request Labels

All pull requests to this repository must include one of the following labels:

**`permanent-change`**: Used for OSSM-specific changes (would not be submitted upstream):
- Mandatory to be cherry-picked to all new minor release branches
- Permanent in OSSM codebase -> added directly to this repository (not synced from upstream)
- Include OpenShift-specific features and customizations

**`no-permanent-change`**: Used for a specific release branch:
- Used for Automator sync PRs
- This PR/commit will NOT be cherry-picked to next minor release branches

**`pending-upstream-sync`**: Use for changes expected to land from Istio upstream:
- PR were merged into supported upstream branches and yet to land into relevant midstream release branches
- For new release branches: cherry-pick automation checks if the commit already landed (synced) from upstream and if found exclude it from the cherry-pick list proposed for the release maintainer

**Purpose**: These labels help release maintainers identify which changes to include when creating new release branches for OSSM. Exactly one label must be applied per PR; applying more than one will fail the label check.
