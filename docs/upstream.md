# Upstream Relationship

## Overview

This repository is the Red Hat midstream fork of [Istio](https://github.com/istio/istio).
It is maintained at
[openshift-service-mesh/istio](https://github.com/openshift-service-mesh/istio) and carries
OpenShift Service Mesh (OSSM) specific patches on top of the upstream Istio codebase.

The midstream fork tracks upstream Istio release branches and adds changes required for
OpenShift integration, FIPS compliance, OSSM-specific bug fixes, and CI configuration.

## Repository Structure

| Role       | URL                                                     |
|------------|---------------------------------------------------------|
| Upstream   | https://github.com/istio/istio                          |
| Midstream  | https://github.com/openshift-service-mesh/istio         |

## Branch Mapping

Each midstream branch tracks the same-named upstream branch.

| Midstream Branch  | Upstream Branch  | OSSM Release |
|-------------------|------------------|--------------|
| `master`          | `master`         | (next)       |
| `release-1.24`    | `release-1.24`   | OSSM 3.0     |
| `release-1.26`    | `release-1.26`   | OSSM 3.1     |
| `release-1.27`    | `release-1.27`   | OSSM 3.2     |
| `release-1.28`    | `release-1.28`   | OSSM 3.3     |
| `release-1.30`    | `release-1.30`   | OSSM 3.4     |
| `release-1.31`    | `release-1.31`   | OSSM 3.5     |

The [sail-operator midstream](https://github.com/openshift-service-mesh/sail-operator)
repository maps its own release branches to specific istio midstream branches. See the
sail-operator repository's `docs/upstream.md` for the full mapping including OCP versions.

## Contribution Workflow

1. **Prefer upstream first.** Changes that are not OSSM-specific should be proposed as pull
   requests to the upstream Istio repository. Once merged upstream, they will be synced to
   the midstream fork.
1. **OSSM-specific changes** that have no relevance to the community project (OpenShift CI
   configs, FIPS patches, OSSM-only features) go directly to the midstream repository.
1. Bug fixes that affect both upstream and midstream should land upstream first to avoid
   divergence.

## Sync Process

Upstream changes are brought into midstream through periodic merges and targeted cherry-picks.

- An automator bot performs routine merges from upstream branches into the corresponding
  midstream branches.
- When the bot merge produces conflicts or when specific commits need to be pulled ahead of
  a full merge, maintainers perform manual cherry-picks.
- After a sync, CI (prow) runs on the midstream branch to validate that OSSM-specific patches
  still apply cleanly and tests pass.

## Coding Conventions

- Follow the coding style and conventions established by the upstream Istio project.
- OSSM-specific patches should be kept as small and isolated as possible.
- Do not modify upstream files unnecessarily; prefer additive changes or configuration-based
  customization.

### Labeling permanent OSSM changes

Changes that are intentional, permanent divergences from upstream (not cherry-pick candidates)
must be labeled so they survive future merges without confusion. Use this comment style:

```go
// OSSM-only: <JIRA-KEY> <short reason>
```

Example:

```go
// OSSM-only: OSSM-12345 FIPS compliance requires non-upstream TLS settings
```

Apply the label on the same line (or the line above for blocks) as the divergent code.
This makes it easy to locate all permanent patches with `git grep "OSSM-only"` and avoids
re-introducing upstream behavior by accident during a merge conflict resolution.

Changes that are intended for upstream contribution but have not landed yet should instead
reference the upstream issue or PR in the commit message, not in a code comment.

## CI Configuration

Prow CI job definitions for the istio midstream are located in the
[openshift/release](https://github.com/openshift/release) repository:

- [ci-operator/config/openshift-service-mesh/istio/](https://github.com/openshift/release/tree/main/ci-operator/config/openshift-service-mesh/istio)

Each file corresponds to a tracked branch:

| Config file                                       | Branch         | Sync job                        | Schedule              |
|---------------------------------------------------|----------------|---------------------------------|-----------------------|
| `openshift-service-mesh-istio-master.yaml`        | `master`       | `sync-upstream-istio-master`    | Periodic, weekdays 05:00 UTC |
| `openshift-service-mesh-istio-release-1.24.yaml`  | `release-1.24` | manual cherry-picks only        | —                     |
| `openshift-service-mesh-istio-release-1.26.yaml`  | `release-1.26` | manual cherry-picks only        | —                     |
| `openshift-service-mesh-istio-release-1.27.yaml`  | `release-1.27` | manual cherry-picks only        | —                     |
| `openshift-service-mesh-istio-release-1.28.yaml`  | `release-1.28` | manual cherry-picks only        | —                     |
| `openshift-service-mesh-istio-release-1.30.yaml`  | `release-1.30` | manual cherry-picks only        | —                     |

**`master` sync**: the `sync-upstream-istio-master` periodic job runs `automator-main.sh` to
open a merge PR from `upstream/istio@master` into `midstream/master` on a weekday schedule.
It applies the `tide/merge-method-merge` and `auto-merge` labels so the PR merges automatically
once CI passes.

**Release branches**: there is no automated upstream-to-midstream sync. Fixes are brought in
via manual cherry-picks. Each release branch config does include an `update-istio-module`
postsubmit that, after any push, opens a PR in the `sail-operator` midstream repository to
bump its `go.mod` dependency pin to the new commit.

## PR Process

| Target             | Where to open the PR                                    |
|--------------------|---------------------------------------------------------|
| Community feature  | https://github.com/istio/istio                          |
| OSSM-only change   | https://github.com/openshift-service-mesh/istio         |

- All PRs are gated by CI (prow). Ensure the relevant tests pass before submitting.
- Reference the relevant JIRA issue in the PR description.

### Required PR labels

All pull requests to the midstream repository must carry exactly one of these labels
(defined in [CONTRIBUTING.md](../CONTRIBUTING.md)):

| Label | When to use |
|-------|-------------|
| `permanent-change` | OSSM-specific change that lives permanently in the midstream: OpenShift features, customizations, compliance patches; must be cherry-picked to every new release branch |
| `no-permanent-change` | Temporary or experimental change that will be removed or replaced by upstream sync; must NOT be cherry-picked to release branches |
| `pending-upstream-sync` | Change awaiting upstream sync; cherry-pick to release branches only until the equivalent lands from upstream Istio |

Exactly one label must be applied per PR — the label check CI job enforces this and will
fail the PR if the label is missing or more than one is set. Automated Automator PRs are
exempt from the check. Labels are used by release maintainers to decide which commits to
carry forward when branching a new OSSM release.
