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

Run this skill in a fresh session (after `/clear`, or a new or forked one), never in the builder's.
Every orchestration step re-reads the session's whole context, so in a builder session hundreds
of thousands of tokens deep the orchestration costs as much as the breaker. A fresh session also
keeps the builder's reasoning away from the brief. If this session already holds the build, say so
and tell the owner: "next: `/clear`, then `/serial-build:red`".

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

Planning the next gate need not wait for this one to ship. If the next written-out roadmap gate
after this one has no draft (`plan-draft.sh status <next-gate>` exits 1), start one now, before
the snapshot: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/plan-draft.sh" start <next-gate>`, then run the
launch command it prints. The draft session works in a worktree outside the project, so it
neither voids this run nor hits the red lock.

## 2. Snapshot, and take the red lock

Stop the dev stack and anything else that writes into the project first: a daemon's log, a
watcher, a test run in another session. Then run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" snapshot`. It refuses, naming the file, while
any watched ignored file was written in the last two minutes, since that writer would void the
run. It records the commit, every ignored file in the project, and the parts of `.git` every
worktree shares (config, exclude rules, hooks), so step 4 can prove none of them moved.

It also takes the red lock. Until verify or abort releases it, a hook refuses every agent but the
red-breaker any write into the project and any shell command not on a short read-only list. This
session can still read, write files outside the project, run `git status` and `ps`, stop a stray
process, and run `red-guard.sh`, `red-pack.sh`, and `red-file.sh`; nothing else.
If a run hangs, or a session died holding the lock, `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" abort`
releases it and voids the run.

## 3. Brief a fresh agent in its own worktree

Launch the `serial-build:red-breaker` agent with `isolation: "worktree"`, so it works in its own
checkout of the last commit (Claude Code puts it at `.claude/worktrees/agent-<id>/` inside the
project) and nothing it does to code reaches the project. Whether the harness runs it in the
foreground or the background, the red lock keeps everything else out of the project until step 5.
Do nothing in the project while it runs.
Give it only what is on disk, never the builder's reasoning or this conversation's account of the
work:

- the gate slug, its Builds, Demo (with the Break it: step), QA, Proof, and Acceptance, from
  `docs/plan.md` and `docs/roadmap.md`;
- the plan's "Tried to break" list: the attacks it must attempt at minimum;
- the test paths it may write (`red.test_paths`) and the command to run one test file:
  `red.test_command` from the config, with `{file}` standing for the file (for example
  `uv run pytest {file} -q -p no:cacheprovider`). Without it, the test commands from CLAUDE.md;
  never the `checks.on_stop` suite, which costs minutes per run and which the commit hooks run
  anyway;
- the context pack: the output of `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-pack.sh" [lane name]`,
  pasted verbatim. It is generated, never written by hand: the files changed since the plan, the
  full changed source in the breaker's slice, and the test fixtures it can reuse. It saves the
  breaker the reading it would otherwise do first and then carry in every later turn; it may
  still read anything;
- the instruction that it did not build this and must not trust any claim that it works.

**Lanes.** When the config has `red.lanes`, launch one breaker per lane, all at once, after the one
snapshot. Each gets the same brief plus its lane's `focus` and its own pack
(`red-pack.sh <lane name>`), and is told:

- the whole "Tried to break" list is its minimum, and its job is to go past the list in its
  slice. It may follow a bug anywhere. Do not narrow the brief to the list: in a measured gate,
  only one of sixteen accepted findings came from running a listed attack as written; seven were
  neighbours of one and eight were beyond the list;
- every subprocess and timing attack belongs to the first lane alone, since parallel load makes
  timing tests flake;
- to name its test files `red_<lane name>_<what>` so lanes never write the same file (a
  collision voids the whole run).

When all lanes return, file them as one run: `red-file.sh` with one `--output` per lane and one
`--worktree` per worktree named. It verifies once, imports from every worktree, files all
outputs as one source, and records one `Red run:` line. A delta run uses one breaker.

A hook fences it while it runs (writes outside the test paths and git commands other than
read-only ones are refused), but the fence is advisory; the checks in step 5 are the guarantee.

## 4. While it runs: watch for a stall

In measured runs about half of the breaker's wall clock was API requests that hung, and a stall
over five minutes also expires the prompt cache, so the whole context is written again at a
higher price. If the harness runs the breaker in the background, check on it every few minutes.
When ten minutes pass with no new tool call or output from it, tell the owner it looks stalled,
what it was last doing, and the choice: wait, or stop it and salvage the run (below). Never stop
it on your own judgement.

## 5. File the run, in one call

Save each agent's full response, verbatim, to a file outside the project (the system temp
folder; the red lock refuses writes inside the project until verify). Then run:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-file.sh" --output <response file> [--worktree <worktree path>] --cost "<duration>, <tokens>"
```

- `--worktree` when the agent's result names a worktree (it does when the agent changed anything
  there; an unchanged worktree and its branch are removed automatically).
- `--cost` is the duration and token count the harness reported for the agent, so the done entry
  states what the red lane really cost.

It does, in order, and stops at the first that fails:

1. `red-guard.sh verify`: the project and the shared `.git` files are as they were (agent
   worktrees, the per-user permissions file, and the linked dependency folders are not watched).
   This releases the red lock.
2. `red-import.sh <worktree> --remove`: copies back only files under the test paths, refusing if
   the agent changed anything else there, deleted a test, or committed. It also deletes the
   `worktree-agent-*` branch Claude Code made for the agent.
3. Files the response verbatim as `docs/decisions/sources/red-<gate-slug>-<YYYY-MM-DD>.md`
   (`-2`, `-3` for later runs that day), so a finding the builder later questions can be checked
   against what the agent actually said.
4. Re-runs each finding's Reproduce command from the project root. One that passes now, or whose
   test did not come back, is recorded as an attempt that found nothing, saying why.
5. Appends the run to the plan's `## Red` section, each finding with its test's blob hash, and
   prints what it wrote.

A failure in 1 or 2 voids the run: nothing is recorded in the project, and the void is remembered
and written above the next run's line. Report what changed, restore it only with the owner's
say-so, salvage the run (below), and start again from step 2.

**Salvaging a voided run.** A voided run's tests are not thrown away, and they are not trusted
either. `red-file.sh` prints the command:
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-import.sh" <worktree path> --quarantine "$(mktemp -d)" --remove`.
It copies only files under the test paths into that folder, outside the project, and records
nothing. Brief the next run with the quarantine folder's path and the voided run's raw output:
judge each quarantined test, write the ones that still reproduce into its own worktree, and then
go past them. A salvage run costs about half a fresh one. Every test the clean run brings back is
re-proven by step 5, as any other.

## 6. Judge each finding

The script checks that each finding fails now; only you can check that it fails for the reason
the agent gave. Read each recorded finding against the raw output and run its test once. One that
fails for another reason (a typo in the test, a missing fixture) is not a finding. Before the
first commit, rewrite its bullet under "Attempts that found nothing" in the form red-file.sh uses,
`- <what it claimed>: <what happened instead> (red-<slug>)`, so it no longer starts with
`- red-`; lower the run line's `<n> findings` by one (the attempts count stays); and remove its
test file if nothing else uses it. Change nothing else. Then run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh" --record`, which checks the uncommitted record,
and fix the section until it passes. Once committed, a run's line and findings can never change:
any edit reopens every finding in it.

## 7. What the record holds

The section `red-file.sh` drafts has this shape; this is the one edit to the plan this skill
makes:

```
## Red

Voided red run: <YYYY-MM-DD>, <cost>. Why: <what changed>.

Red run: <YYYY-MM-DD>, <n> attempts, <n> findings. Source: `red-<gate-slug>-<YYYY-MM-DD>`. Cost: <duration>, <tokens>.

- red-<slug>: <what breaks, consequence first>. Test: `<test file path>@<git blob hash>`. Reproduce: `<command>`.

Attempts that found nothing:
- <attack>: <what was run, what happened>
```

- `<git blob hash>` is `git hash-object <test file path>` at filing. The handoff reopens a finding
  whose test file is deleted or changed from that content, or whose line here changes after it is
  committed; a red test is fixed by fixing the code, never the test.
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

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh" --record` before this commit, never after:
a committed run cannot be corrected. After committing, run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh"`; its findings are expected to be OPEN until the
builder fixes them.

## After the fixes: the delta run

Once the builder has fixed the findings, run this skill again as a delta run before the handoff
(a run with no findings needs none).
A fix often moves the bug one step over, and a fixed finding is otherwise only re-tested, never
attacked. Steps 2 to 9 are the same; the brief differs:

- the fix commits (`git log --oneline <the Red commit>..HEAD`) and the findings they close;
- "attack the fixes and their neighbours": inputs one step from each fixed case, the same bug
  through another path, and what the fix itself made newly possible;
- the plan's "Tried to break" list is not re-run; its minimum was met by the first run, so the
  delta run's declared attempts may be fewer than the list.

It records its own `Red run:` block, as any later run does.

## When a finding is wrong, or its test must change

- **Wrong finding** (the test asserts something the product should not do): only the owner decides,
  never this session on its own judgement. Ask the owner with AskUserQuestion, one question per
  finding: what the test asserts, why it may be wrong, and the options "Demote it" and "Keep it
  open". Only on "Demote it", run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --demote red-<slug> --owner-said "<their answer, verbatim>"`,
  passing exactly what they chose or typed. It records and commits the demotion; a typed
  "Demoted" line does not count. With no owner to ask (a headless run), leave the finding open.
- **A fix had to change the test** (an import moved): launch one judge run for those findings,
  all of them together. It is not a red run: skip steps 2 to 8 (no snapshot, no red-file.sh, no
  Red run line). Brief the red-breaker agent with each old and new test and ask whether each new
  one still asserts the same behaviour; save its answer verbatim yourself as
  `docs/decisions/sources/red-repin-<gate-slug>-<YYYY-MM-DD>.md` under a short header.
  For the ones it says yes to, run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-repin.sh" red-<slug> [red-<slug>...] --source <that source's slug>`.
  The script refuses, re-pinning none, unless each changed test still fails on the commit that
  recorded its finding, from before the fix, and commits all the re-pins together.

## 9. Report

Consequence first, to the owner: how many attacks, what broke and what that would have meant for
a user, and the next step, which is the builder fixing each finding (a fix is ordinary product
code; the red lane never writes it). Quote the last line of `red-status.sh`: the gate cannot
hand off until it says clear.

End with the next command, to run after `/clear` or in a new session: with findings, "next:
`/clear`, then fix the red findings in `docs/plan.md`, then `/clear` and `/serial-build:red` for
the delta run"; after a delta run with none open, "next: `/clear`, then
`/serial-build:demo-brief`".
