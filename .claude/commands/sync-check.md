# Sync Check — determine the correct PR label

Answer these questions in order to determine the correct PR label.

## Step 1: Is this change OSSM-specific by nature?
Examples: OCP-specific CI config, OSSM branding, Red Hat compliance patches, `.gitignore` updates for OSSM tooling.

→ If YES: apply `permanent-change`. Stop.

## Step 2: Does the equivalent fix/feature already exist in upstream Istio main?
Check: https://github.com/istio/istio

→ If YES: apply `no-permanent-change`. Reference the upstream commit or PR in the description.

## Step 3: Is there an open upstream Istio PR for this change?
→ If YES: apply `pending-upstream-sync`. Link the upstream PR.

## Step 4: Does this change belong upstream but no PR exists yet?
→ Open an upstream PR first, then apply `pending-upstream-sync`.

## Label summary

| Situation | Label |
|---|---|
| OSSM-only forever | `permanent-change` |
| Already upstream / being reverted | `no-permanent-change` |
| Upstream PR open or planned | `pending-upstream-sync` |
