# Contribution guidelines

So you want to hack on Istio? Yay! Please refer to Istio's overall
[contribution guidelines](https://github.com/istio/community/blob/master/CONTRIBUTING.md)
to find out how you can help.

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

**Purpose**: These labels help release maintainers identify which changes to include when creating new release branches for OSSM.
