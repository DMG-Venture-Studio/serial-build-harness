---
name: red
description: Send a fresh agent that did not build the active gate to break it, from its own git worktree. Its only outputs are a failing test, brought back and committed, or "nothing found" with every attempt listed; it never edits the fix. Use on every gate before the handoff, after the builder believes the gate is done.
argument-hint: Optional gate slug, default the gate in docs/plan.md
---

Gate asked for: "$ARGUMENTS" (empty means the gate in docs/plan.md).

The red lane exists because a gate proven green by the session that built it tends to cover
only the scenario it was written for. A reviewer whose goal is to make things fail finds what
the builder's own checks cannot. This skill runs that reviewer and records what it reproduces
where the handoff can check it mechanically. You, the session running this skill, are not the
breaker: you brief it, isolate it, verify it, and record.

Scripts are under `${CLAUDE_PLUGIN_ROOT}/scripts`; run them with `sh` from the project root.

## 1. Preconditions

- `.claude/serial-build.json` has `red.test_paths`, which tells a test from the code under test.
  Check with `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-config.sh"`; without it, stop and say so.
- `docs/plan.md` exists and names the gate. The red lane attacks the active gate only.
- The gate's work is committed. The breaker works in a worktree cut from the last commit, so
  uncommitted work would go unattacked; the snapshot below refuses until it is committed.
- `.claude/settings.json` has `worktree.baseRef` set to `"head"` (without it Claude Code cuts the
  worktree from the remote's default branch, so the breaker would attack the pushed code, not
  this gate) and `worktree.symlinkDirectories` naming the dependency folders the tests need
  (`node_modules`, `.venv`); `.worktreeinclude` names small ignored files to copy (`.env`).
  `/serial-build:scope` writes these; without them the breaker's tests cannot run in its worktree.

## 2. Snapshot

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" snapshot`. It records the commit, every
ignored file in the project, and the parts of `.git` every worktree shares (config, exclude
rules, hooks), so step 4 can prove none of them moved.

## 3. Brief a fresh agent in its own worktree

Launch the `serial-build:red-breaker` agent in the foreground with `isolation: "worktree"`, so it
works in its own checkout of the last commit (Claude Code puts it at
`.claude/worktrees/agent-<id>/` inside the project) and nothing it does to code reaches the
project.
Give it only what is on disk, never the builder's reasoning or this conversation's account of the
work:

- the gate slug, its Builds, Demo (with the Break it: step), QA, Proof, and Acceptance, from
  `docs/plan.md` and `docs/roadmap.md`;
- the plan's "Tried to break" list: the attacks it must attempt at minimum;
- the test paths it may write (`red.test_paths`) and the test commands from the config's
  `checks.on_stop` rules and CLAUDE.md;
- the instruction that it did not build this and must not trust any claim that it works.

A hook fences it while it runs (writes outside the test paths and git commands other than
read-only ones are refused), but the fence is advisory; the next two steps are the guarantee.

## 4. Verify, then bring the tests home

1. `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" verify`: the project and the shared `.git`
   files are as they were (agent worktrees, the per-user permissions file, and the linked
   dependency folders are not watched). A failure voids the run: report what changed, restore it only with
   the owner's say-so, and start again from step 2.
2. If the agent's result names a worktree (it does when the agent changed anything there; an
   unchanged worktree and its branch are removed automatically), run
   `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-import.sh" <worktree path> --remove`. It copies back only
   files under the test paths and refuses, copying nothing, if the agent changed anything else
   there, deleted a test, or committed; a refusal voids the run the same way. It also deletes the
   `worktree-agent-*` branch Claude Code made for the agent.

## 5. File the raw output

Save the agent's full response, verbatim, as
`docs/decisions/sources/red-<gate-slug>-<YYYY-MM-DD>.md` (add `-2`, `-3` for a second run on one
day) under a short header: which gate, which run, that it is the red-breaker agent's unedited
output. The record below cites it, so a finding the builder later questions can be checked
against what the agent actually said.

## 6. Reproduce each finding yourself

For each finding, run its reproduce command from the project root. A finding counts only if the
command fails now, for the reason the agent gave. One that passes, or fails for another reason
(a typo in the test, a missing fixture), is not a finding: record it under "Attempts that found
nothing" with what happened, and remove its test file if nothing else uses it.

## 7. Record where the handoff can check it

Append to `docs/plan.md` (create the section if it is absent; this is the one edit to the plan
this skill makes):

```
## Red

Red run: <YYYY-MM-DD>, <n> attempts, <n> findings. Source: `red-<gate-slug>-<YYYY-MM-DD>`.

- red-<slug>: <what breaks, consequence first>. Test: `<test file path>@<git blob hash>`. Reproduce: `<command>`.

Attempts that found nothing:
- <attack>: <what was run, what happened>
```

- `<git blob hash>` is the output of `git hash-object <test file path>` now. The handoff reopens
  a finding whose test file is deleted or changed from that content, or whose line here changes
  after it is committed; a red test is fixed by fixing the code, never the test.
- Every attempt is listed: the fruitless ones here and the rest as findings, adding up to at least
  the declared count, which is at least the number of bullets on the plan's "Tried to break" list.
- A finding may wrap onto indented lines; it is read as one bullet.
- A later run adds its own `Red run:` block under the same section; earlier findings stay.
- Never edit a recorded finding, its test, or its line. `red-status.sh` compares each against the
  commit that recorded it and reopens any that changed.

## 8. Commit, then check

The record counts only once committed. Commit the imported tests, the raw output, and the plan's
Red section as "Red: <gate-slug>, <n> findings". The tests are committed failing, on purpose, so:
if the gate is being built on its own branch, commit there. If the work is on the default branch,
say before committing that continuous integration and any pre-commit test hook will fail until
the fixes land, and ask the owner whether to commit now or on a new branch for the gate.

Then run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh"`. Its record checks must pass (fix the
section, commit, and rerun until they do); its findings are expected to be OPEN until the builder
fixes them.

## When a finding is wrong, or its test must change

- **Wrong finding** (the test asserts something the product should not do): only the owner decides,
  never this session on its own judgement. Ask the owner with AskUserQuestion, one question per
  finding: what the test asserts, why it may be wrong, and the options "Demote it" and "Keep it
  open". Only on "Demote it", run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --demote red-<slug> --owner-said "<their answer, verbatim>"`,
  passing exactly what they chose or typed. It records and commits the demotion; a typed
  "Demoted" line does not count. With no owner to ask (a headless run), leave the finding open.
- **A fix had to change the test** (an import moved): run this skill again for that finding. Brief
  the red-breaker agent with the old and new test and ask whether the new one still asserts the
  same behaviour; file its answer as a decision source. If it says yes, run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-repin.sh" red-<slug> --source <that source's slug>`. The
  script refuses unless the changed test still fails on the commit that recorded the finding,
  from before the fix, and commits the re-pin itself.

## 9. Report

Consequence first, to the owner: how many attacks, what broke and what that would have meant for
a user, and the next step, which is the builder fixing each finding (a fix is ordinary product
code; the red lane never writes it). Quote the last line of `red-status.sh`: the gate cannot
hand off until it says clear.
