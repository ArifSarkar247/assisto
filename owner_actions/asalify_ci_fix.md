# Asalify CI fix — apply yourself (30 seconds)

**Why:** `.github/workflows/ci.yml` triggers on EVERY push+PR, has no `concurrency`
(rapid pushes each run a full job, none cancelled) and no `timeout-minutes`
(a hung step runs up to GitHub's 6-hour default). That is how ~2,000 free
Actions minutes can be burned in one day.

**Fix (edit ONLY this file — add the 2 marked blocks; nothing else changes):**

In `.github/workflows/ci.yml`:

1. Right after the `on: [push, pull_request]` line, add:

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

2. Under `  test:` , right after `    runs-on: ubuntu-latest`, add:

```yaml
    timeout-minutes: 15
```

That's it — leave every other line of the workflow exactly as-is.

(Claude did NOT modify the Asalify repo, per the "never touch Asalify" rule.)
