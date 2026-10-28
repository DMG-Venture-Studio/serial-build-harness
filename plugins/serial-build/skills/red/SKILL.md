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

## When to run

- **Once the builder believes the gate is done**, the usual case.
- **A partial run, earlier**, when the builder is blocked for 30 minutes or more on something
  outside the repository (CI, a platform deploy, an account the owner must create) and some of
  the gate's slices are finished. Finished code otherwise waits hours to be attacked. Brief with
  `red-brief.sh --partial "<the finished slices, in words>"` and file with `red-file.sh --partial`.
  The builder stops editing for the run (the red lock enforces it). Its findings go to the
  red-fixer as in step 9, but no delta run follows them: the next red run is the run before
  handoff, once the builder has finished, briefed with `--delta` (red-brief.sh sees the partial
  run and briefs a full attack on everything built since, plus the attacks the partial run listed
  as not yet built). The partial run and that one together meet the list's minimum; a partial
  run alone never does. Without an outside wait, a partial
  run only costs one more run.

## 1. Preconditions

- `.claude/serial-build.json` has `red.test_paths`, which tells a test from the code under test.
  Check with `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-config.sh"`; without it, stop and say so.
- When it has `threat_model` (the section saying which actors and setups the project's checks
  defend against), check-config.sh must read it without an ERROR: red-brief.sh copies it into
  every brief and refuses while it names nothing it can read. A failure that needs a setup it
  excludes comes back under "For intake", never as a finding, so the red rounds are spent on what
  can actually happen. With none declared, every brief still sends contrived setups to intake.
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
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" snapshot --wait`, with the Bash tool's timeout
at its 10-minute maximum. The end-of-turn test suite (`checks.on_stop`) runs right after the
commit step 1 asked for and writes its caches into the project, so the snapshot waits until that
suite has finished and no watched ignored file has been written for two minutes, then proceeds;
never write a wait loop of your own. After 9 minutes it gives up, naming what still writes, since
that writer would void the run: stop it and snapshot again. It records the commit, every ignored file in the project, and the parts of `.git` every
worktree shares (config, exclude rules, hooks), so step 4 can prove none of them moved.

It also takes the red lock. Until verify or abort releases it, a hook refuses every agent but the
red-breaker any write into the project and any shell command not on a short read-only list. This
session can still read, write files outside the project, run `git status` and `ps`, stop a stray
process, and run `red-guard.sh`, `red-pack.sh`, and `red-file.sh`; nothing else.
If a run hangs, or a session died holding the lock, `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-guard.sh" abort`
releases it and voids the run.

## 3. Brief a fresh agent in its own worktree

Generate the brief; never type it. From the project root:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-brief.sh" --out "<a folder outside the project>" [--lane <name>] [--delta | --partial "<finished slices>"] [--quarantine <folder>]
```

Use the session's scratch or temp folder for `--out`; the red lock refuses writes inside the
project. It writes `brief.md` and the context pack `pack.md` there (`brief-<lane>.md` and
`pack-<lane>.md` for a lane) and prints the one line to brief the agent with: "Read <brief> and
follow it." The brief is generated from what is on disk, never the builder's reasoning or this
conversation's account of the work: the instruction that the agent did not build the gate; the
acceptance sentence, Proof, and roadmap section; the attack order (the surface the demo and the
acceptance sentence depend on first, the plan's Supporting items after); the "Tried to break"
minimum; the run's mode; the test paths and the single-file test command (`red.test_command`;
never the `checks.on_stop` suite, which costs minutes per run); the pack's path; and the report
form from `agents/red-breaker.md`, which red-file.sh reads mechanically.

Launch the `serial-build:red-breaker` agent with `isolation: "worktree"` and that one line as its
prompt, so it works in its own checkout of the last commit (Claude Code puts it at
`.claude/worktrees/agent-<id>/` inside the project) and nothing it does to code reaches the
project. Whether the harness runs it in the foreground or the background, the red lock keeps
everything else out of the project until step 5. Do nothing in the project while it runs.

**Lanes.** When the config has `red.lanes`, run `red-brief.sh --lane <name>` for each lane and
launch one breaker per lane, all at once, after the one snapshot. Each brief tells its agent that
the whole "Tried to break" list is its minimum and its job is to go past it in its slice (in a
measured gate only one of sixteen accepted findings came from running a listed attack as written;
seven were neighbours of one and eight were beyond the list), that subprocess and timing attacks
are the first lane's alone, and to name its test files `red_<lane>_<what>` (a collision voids the
run). When all lanes return, file them as one run: `red-file.sh` with one `--output` per lane and
one `--worktree` per worktree named. A delta run uses one breaker.

**A run may brief only some lanes.** Standing rule: skip a lane whose `paths` are only check
tooling (the project's own checks, hooks, and CI scripts, not product code) when the gate's last
pre-push adversarial report on those paths, where the project runs one, ended in an approving
verdict ("Approve as is" or "Fold and approve"). A breaker there would attack code a reviewer has
just approved: in the source project one breaker run cost 150k to 230k tokens and 20 to 25
minutes, and the fix rounds it started cost more. Never skip the first lane by this rule, since
it holds every subprocess and timing attack; any other skip is the owner's call. Each lane that
runs still meets the whole "Tried to break" list. File the run with one
`--skipped "<lane>: <why>"` per lane not briefed, naming the report, so the record says which
lanes ran and why the others did not.

A hook fences the breaker while it runs (writes outside the test paths and git commands other than
read-only ones are refused), but the fence is advisory; the checks in step 5 are the guarantee.

## 4. While it runs: watch for a stall

In measured runs about half of the breaker's wall clock was API requests that hung, and a stall
over five minutes also expires the prompt cache, so the whole context is written again at a
higher price. If the harness runs the breaker in the background, check on it every few minutes.
When ten minutes pass with no new tool call or output from it, tell the owner it looks stalled,
what it was last doing, and the choice: wait, or stop it and salvage the run (below). Never stop
it on your own judgement.

## 5. File the run, in one call

Save each agent's full response, verbatim, with the Write tool, to a file outside the project
(the session's scratch or temp folder; the red lock refuses writes inside the project until
verify, and refuses a shell heredoc anywhere). Then run:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-file.sh" --output <response file> [--worktree <worktree path>] --cost "<duration>, <tokens>"
```

- `--worktree` when the agent's result names a worktree (it does when the agent changed anything
  there; an unchanged worktree and its branch are removed automatically).
- `--cost` is the duration and token count the harness reported for the agent, so the done entry
  states what the red lane really cost.
- `--delta` for a delta run, `--partial` for a partial run, so the run line says which.
- `--skipped "<lane>: <why>"` for each lane of `red.lanes` this run did not brief (step 3); the
  run line names it and the filed source says why. Fewer outputs than lanes is otherwise fine.

Besides the drafted section it prints the findings' kinds (fix each once), anything the agent put
under "For intake" (message wording, a setup outside the threat model, or anything outside the
gate: file those through `/serial-build:intake`, never into the plan), and, on the second delta
run with findings, a STOP line (see step 9).

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

Red run: <YYYY-MM-DD>, <n> attempts, <n> findings. Source: `red-<gate-slug>-<YYYY-MM-DD>`.[ Delta run.| Partial run.][ Lanes skipped: <lane>.] Cost: <duration>, <tokens>.

- red-<slug>: <what breaks, consequence first>. Kind: `<class>`. Test: `<test file path>@<git blob hash>`. Reproduce: `<command>`.

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

## 9. The fix and delta loop, chained

A run with findings is not handed back to the owner to `/clear` and type the next step; each of
those waits measured longer than the breaker runs themselves. This session chains the loop,
holding only file paths and verdicts, never the code, and every agent it launches starts fresh:

1. **Fix.** Launch the `serial-build:red-fixer` agent in the project (no worktree), with the one
   line "Fix the red findings in docs/plan.md's Red section, following your instructions." It is
   a fresh builder, never the breaker. It fixes each kind once, in the one place the class should
   be handled, with one table-driven test that enumerates the class (for configuration errors:
   every variable times unset, blank, malformed, and wrong-but-plausible, times every entry
   point), not one patch and one test per reported case. Point fixes are what kept a measured
   gate looping for three rounds; the class fix took fourteen minutes and closed five findings.
2. **Read its report.** "Looks wrong" items go to the owner (below). "Tests that must change" go to
   a re-pin judgement (below). "Shipped tests that must change" go to the owner as the shipped-gate
   case (below); never edit one. Then run `red-status.sh`: every finding it reports fixed must read
   RESOLVED.
3. **Delta run.** Back to step 2, briefed with `red-brief.sh --delta` and filed with
   `red-file.sh --delta`. It is regressions only: what the fixes made newly possible, and cases
   of each fixed kind that the enumerating tests miss, never fresh neighbours in untouched code.
   Its declared attempts may be fewer than the "Tried to break" list, whose minimum the first run
   met.
4. **Repeat** from 1 while the delta run finds something, with one limit: when red-file.sh prints
   STOP (the second delta run with findings), do not fix again; a third round patches the next
   neighbour. Put the owner one line: a structural change that removes the whole class (a
   narrower gate, or refusing the class outright), or accepting the risk (each open finding
   demoted on their words, below, and filed through `/serial-build:intake`). This is the same
   stopping rule the project's process rules set for adversarial rounds on check code: two fold
   rounds, then the owner's one-line choice, never a third fold.
5. **After a structural change.** When the owner chooses it, launch the `serial-build:red-fixer`
   agent once more, with the line "Fix the red findings in docs/plan.md's Red section, following
   your instructions. The owner chose a structural change: '<their choice, verbatim>'." It makes
   that change instead of a per-kind fix. Read its report as in 2, route every test it lists, and
   run `red-status.sh`, which must read clear. No delta run follows, and no further red run is due
   on that code for this gate: a third adversarial round on it is the round the stopping rule
   forbids. Then step 10.

Stop and ask the owner only for: a finding that may be wrong (the demote question), the STOP
above, or a clean run, when the loop ends and step 10 names the next command.

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
- **A fix broke a shipped gate's test** (a test a `Proof:` command in `docs/done.md` runs, such as
  an earlier gate's red test): never edit it, and the re-pin above does not cover it, since it
  belongs to no finding in the active plan. Ask the owner with AskUserQuestion, one question per
  test: which gate's proof runs it, what now fails and why the fix forces it, and the options
  "Retire the proof" and "Move the gate back". On "Retire the proof", record the decision
  through `/serial-build:intake` (the record names the test and that it is retired on purpose),
  then run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --retire-proof <gate-slug> "<proof command>" --decision <slug> --owner-said "<their answer, verbatim>"`;
  it warns when the active plan's Proof block still runs the same test, which the plan must drop
  before the test is deleted. On "Move the gate back", run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --regress <gate-slug> --failed "<the failing output>"`.

## 10. Report

Consequence first, to the owner: how many runs and attacks, what broke and what it would have
meant for a user, each kind and how it was fixed, and what the loop cost. Quote the last line of
`red-status.sh`: the gate cannot hand off until it says clear.

End with the next command, to run after `/clear` or in a new session: when the loop ended clean,
"next: `/clear`, then `/serial-build:demo-brief`"; when it stopped for the owner, what it needs
from them.
