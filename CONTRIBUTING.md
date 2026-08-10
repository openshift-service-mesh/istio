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

**`permanent-change`**: Use for OSSM-specific changes that:
- Are added directly to this repository (not synced from upstream)
- Should be cherry-picked to new release branches
- Include OpenShift-specific features and customizations
- Will remain permanently in the OSSM codebase

**`no-permanent-change`**: Use for temporary changes that:
- Will be removed from the repository in the future
- Should NOT be cherry-picked to release branches
- Are experimental or short-term modifications
- Will be replaced by upstream synchronization

**`pending-upstream-sync`**: Use for changes awaiting upstream synchronization that:
- Should be cherry-picked to release branches only until the equivalent change is synced from upstream Istio
- Are backported from upstream but not yet in the midstream sync
- Will eventually be replaced by the upstream version

**Purpose**: These labels help release maintainers identify which changes to include when creating new release branches for OSSM. Exactly one label must be applied per PR; applying more than one will fail the label check.
