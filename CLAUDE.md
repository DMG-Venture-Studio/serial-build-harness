# serial-build-harness

## Fixes ship without asking

Every fix gets a commit, a push, a pull request, and a merge, without asking
first. That standing approval covers fixes only; other changes still ask before
they push.

1. Branch off `main` as `claude/<short-slug>` (never commit to `main`).
2. Run the unit tests, `sh tests/run.sh`, from the repository root. This repo
   has no CI, so this local run is the only gate: it must end `0 failed`.
3. Commit, push, and open the PR with `gh pr create`. The PR body names the
   bug, what broke because of it, and the tests that now cover it.
4. Merge only after the tests pass: `gh pr merge --merge --delete-branch`.
   If the tests fail, do not merge; fix them or report the failure.
