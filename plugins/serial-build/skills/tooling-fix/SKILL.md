---
name: tooling-fix
description: Fix the project's check-tooling repairs that intake queued under "## Tooling fixes" in docs/roadmap.md, in one pass of their own, from a worktree, outside any product gate. Use when intake queued tooling fixes, or the owner asks to fix the check-tooling backlog.
argument-hint: Optional slugs of the items to fix, default every item in the section
---

Items asked for: "$ARGUMENTS" (empty means every item under `## Tooling fixes`).

Check tooling is the project's own checks, not its product: the scripts, rules and loaders that
`checks` in `.claude/serial-build.json`, the git hooks, and CI run, and their tests. Its repairs
get a fix pass of their own instead of riding with the next product gate. Folded into a product
gate, they put the check code back under that gate's red lane, and a repair that keeps failing
blocks a ship that has nothing to do with it. This pass is not a gate: no plan, no demo, no done
entry. It is proven by its enumerating tests and an adversarial review of the change, and it
merges only while no gate is active, so the active gate ships exactly what its red lane attacked.

Scripts are under `${CLAUDE_PLUGIN_ROOT}/scripts`; run them with `sh` from the project root. Run
this skill in a fresh session, never in a builder's.

## 1. Preconditions

- `docs/roadmap.md` has a `## Tooling fixes` section with at least one bullet. If not, there is
  nothing to fix: say so and stop.
- No red run is in progress: the red lock refuses every write into the project but the
  red-breaker's. Wait for `/serial-build:red` to file its run.
- If the branch `serial-build/tooling-fix` already exists, a pass is built and waiting to merge:
  go to step 4.

## 2. Fix, in a worktree outside the project

Cut the branch and its worktree outside the project, so nothing written there reaches the active
gate, the red guard, or the red lock:

```
wt="$(sh -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"; SB_ROOT=$(pwd); sb_state_dir')/tooling-fix"
git worktree add -b serial-build/tooling-fix "$wt" HEAD
```

Launch the `serial-build:red-fixer` agent with the one line "A tooling fix pass: fix the items
<slugs> under `## Tooling fixes` in docs/roadmap.md, following your instructions, working and
committing only in <the worktree's path>." It groups the items by kind and fixes each kind once,
with one test that enumerates the class, as for red findings.

## 3. Review the change

Run the project's test commands (CLAUDE.md, `checks.on_stop`) in the worktree. Then launch the
`serial-build:adversarial-reviewer` agent in change-review mode on the branch's commits
(`git log HEAD..serial-build/tooling-fix` from the project root: the diff against where it was
cut). A major finding
goes back to the red-fixer, briefed with the finding verbatim. The stopping rule for check code
holds here too: after two review rounds that still find something, do not fix again; put the
owner one line, a structural change that removes the whole class, or accepting the risk (each
item that stays open filed through `/serial-build:intake`).

## 4. Merge only while no gate is active

While `docs/plan.md` exists, a gate is active: do not merge. Its red lane attacked the check
tooling as it stands, and the gate must ship what was attacked. Leave the branch and say so in the
report: "merge after the handoff: run `/serial-build:tooling-fix` again".

With no active plan, from the project root:

1. `git merge --no-ff serial-build/tooling-fix -m "Tooling fix: <the slugs, and what each now does>"`.
2. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/run-proofs.sh"` (in the background when it may outlast
   the tool's timeout). The shipped gates' proofs run through the tooling just changed, so every
   one must still pass. On a failure, `git reset --hard ORIG_HEAD` undoes the merge; report the
   failing proof and leave the branch.
3. Remove each fixed item's bullet from `## Tooling fixes` (the section's heading too when it is
   empty), and commit as "Tooling fix: close <slugs>".
4. `git worktree remove "$wt" && git branch -d serial-build/tooling-fix`.

## 5. Report

Consequence first, to the owner: what each repair stops from going wrong, the enumerating test
that proves it, what the review found, and what stays queued. End with the next command: if a gate
is active, its next step ("next: continue `docs/plan.md`"), else `/serial-build:gate` on the first
written-out roadmap gate.
