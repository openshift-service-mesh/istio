# Upstream Sync Review — istio midstream

Evaluate whether a set of changes is correctly labeled and ready for the midstream sync workflow.

## Step 1: Identify OSSM-only hunks

- Read each changed file.
- Flag any hunk that is OSSM-specific and lacks an `// OSSM-only: <JIRA-KEY> <reason>` annotation.

## Step 2: Check PR label correctness

Apply the decision tree from `.claude/commands/sync-check.md`.

- If label is wrong, state the correct label and the reason.

## Step 3: Upstream existence check

For every non-`permanent-change` hunk:

- Verify the equivalent fix exists (or has a tracking PR) in `github.com/istio/istio`.
- If missing: flag as **upstream gap** and recommend opening an upstream issue.

## Step 4: Generated file check

- Confirm no `*.pb.go`, `*.gen.go`, or `vendor/` files are manually edited.

## Step 5: Summary report

Produce a table:

| File | Hunk | OSSM-only annotated? | Label correct? | Upstream gap? |
|---|---|---|---|---|
