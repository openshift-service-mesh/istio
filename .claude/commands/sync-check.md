# Sync Check — determine the correct PR label

Answer these questions in order to determine the correct PR label.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the authoritative definitions.

## Step 1: Is this change OSSM-specific by nature?

Examples: OCP-specific CI config, OSSM branding, Red Hat compliance patches, `.gitignore` updates for OSSM tooling.

→ If YES: apply `permanent-change`. This change must be cherry-picked to all future minor release branches. Stop.

## Step 2: Is this an Automator sync PR for a specific release branch?

Examples: PRs opened by the `openshift-service-mesh-bot` to sync a release branch with upstream changes.

→ If YES: apply `no-permanent-change`. This change is scoped to one release branch and will **not** be cherry-picked to next minor release branches. Stop.

## Step 3: Has this change already merged into a supported upstream Istio branch?

Check the relevant upstream branch at <https://github.com/istio/istio>. The change exists upstream but has not yet landed in the relevant midstream release branch.

→ If YES: apply `pending-upstream-sync`. The cherry-pick automation will exclude this commit once it syncs from upstream.

## Step 4: Does this change belong upstream but is not yet merged there?

→ Open an upstream PR first, then come back and apply `pending-upstream-sync` once it merges into a supported upstream branch.

## Label summary

| Situation | Label |
|---|---|
| OSSM-specific forever | `permanent-change` |
| Automator release-branch sync PR | `no-permanent-change` |
| Already merged upstream, not yet in midstream | `pending-upstream-sync` |
