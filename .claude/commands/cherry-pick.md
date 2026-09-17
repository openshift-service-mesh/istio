# Cherry-pick to release branch

Use this workflow to backport a commit from master to a release branch.

### Step 1: Identify the commit

Use the original (non-merge) commit SHA where possible.
If you must use a merge commit, pass `-m 1` to specify the mainline parent:

```bash
git cherry-pick -x -m 1 <merge-sha>
```

### Step 2: Checkout the release branch

```bash
git fetch midstream
git checkout release-X.Y
```

### Step 3: Cherry-pick

```bash
git cherry-pick -x <sha>
```

Resolve conflicts if needed. Keep `// OSSM-only:` annotations intact.

### Step 4: Verify tests pass locally

```bash
make test
```

### Step 5: Push and open a PR

Target `openshift-service-mesh/istio:release-X.Y`:

```bash
git push origin cherry-pick-<sha>-to-release-X.Y
gh pr create --base release-X.Y --title "cherry-pick: <original title>" \
  --body "Cherry-pick of <sha> from master.\n\nOriginal PR: #<pr-num>"
```

### Step 6: Apply label

Apply the same label as the original PR.
