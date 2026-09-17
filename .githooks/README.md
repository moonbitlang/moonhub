# Git Hooks

## Pre-commit Hook

The tracked pre-commit hook runs these commands in this exact order and stops
immediately if any command fails:

```sh
moon check --deny-warn
moon fmt
moon info
```

### Usage Instructions

To use this pre-commit hook:

1. Make the hook executable if it isn't already:
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. Configure Git to use the hooks in the .githooks directory:
   ```bash
   git config --local core.hooksPath .githooks
   ```

3. The hook automatically runs when you execute `git commit`, including from a
   subdirectory. `moon` must be available on Git's `PATH`.

### Index Safety

Stage the intended tracked changes and MoonBit inputs before committing. The
hook rejects unstaged tracked changes and non-ignored untracked `.mbt`, `.mbt.md`,
`.mbti`, `moon.pkg[.json]`, and `moon.mod[.json]` files before running the tools.
This deliberately rejects partial staging: checking the working tree must not
approve a different version in the index. Non-MoonBit untracked notes are allowed.

If formatting or interface generation changes a file, the hook stops the commit
and leaves the result in the working tree for review. New generated interfaces
also stop the commit. Review and stage the changes, then retry. The hook never
runs `git add`, stashes work, or discards changes. It also checks staged whitespace.

Configuration is local to each clone; Git does not enable repository hooks on
clone. This is a local workflow guard, not a server-side enforcement mechanism.

### Verification

Run the isolated Git fixture tests without modifying the current index:

```sh
node --test scripts/pre-commit-hook-test.cjs
```

The tests use a mock `moon` executable to check ordering, fail-fast behavior,
format/interface changes, and index preservation. They do not replace running
the actual MoonBit checks before a real commit.
