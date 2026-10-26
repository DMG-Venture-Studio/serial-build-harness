---
name: gate
description: Plan the next roadmap gate on Claude's plan mode, after an adversarial review of every draft, and write docs/plan.md on the product owner's approval. Use whenever a gate comes up for planning in a serial-build project; never another planning skill for a gate.
argument-hint: Optional gate slug, default the first gate in docs/roadmap.md
---

Gate asked for: "$ARGUMENTS" (empty means the first gate in docs/roadmap.md).

Draft `docs/plan.md` for one gate, using Claude Code's own plan mode for the reading and the
approval. The product owner is `owner.name` in `.claude/serial-build.json`; address them by name
and follow the writing rules in CLAUDE.md. A plan is tasks, the attacks the red lane must try,
and what blocks it; never design opinions, alternatives, or estimates.

## 1. One plan at a time

Read the gate in `docs/roadmap.md`: the first `###` gate, written out with every section. If
the roadmap has only one-line gates in a Later list left, the next one is written out in full
through `/serial-build:intake` first; a one-line gate is not plannable. If `docs/plan.md`
exists, there is an active plan: say so, and offer to draft the next written-out gate ahead
instead (below). Never write a second `docs/plan.md`.

Scripts are under `${CLAUDE_PLUGIN_ROOT}/scripts`; run them with `sh` from the project root.

**A draft is waiting.** Run `plan-draft.sh status <gate-slug>`. When it says a draft is saved, the
drafting and its review passes are done; check what moved since with
`plan-draft.sh delta <gate-slug>`:

- exit 0, nothing it depends on changed: call EnterPlanMode, read the draft with
  `plan-draft.sh take <gate-slug>`, and go to step 5 with it;
- exit 3, something changed (a file its tasks name, its roadmap section, a decision record, an
  open question): call EnterPlanMode, take the draft, and run one adversarial review pass on the
  change only (step 4's brief, given the draft and the delta's list), fold what it finds, then go
  to step 5.

After step 5 writes `docs/plan.md`, run `plan-draft.sh drop <gate-slug>`. A draft that status
says is still in progress is a draft session that has not finished; say so and wait, or drop it
and plan from scratch.

**Drafting ahead (`--draft <gate-slug>`).** Planning need not wait for the active gate to ship.
While gate N is in red, demo, or handoff, draft gate N+1, the next written-out roadmap gate after
the active one:

1. From the project, `plan-draft.sh start <gate-slug>` cuts a branch and a worktree outside the
   project and prints the command that launches the draft session there in the background. A
   session outside the project folder cannot void a red run or hit the red lock.
2. In that session ("$ARGUMENTS" is `--draft <gate-slug>`): skip the rest of step 1 entirely
   (the plan there is gate N's, and the draft's status reads "in progress" because this session
   is the one making it). Run steps 2 to 4 for the named gate without plan mode (nobody is
   there to approve, and the worktree is not the project), writing the draft to `docs/plan.md`
   in the worktree. Then run `plan-draft.sh save <gate-slug>`, which commits it on the draft's
   branch with the commit it was reviewed against. Never call ExitPlanMode or ask the owner; end
   with one line naming the gate and the review result.

The owner approves a draft only when this skill takes it, as above, in the same sitting as gate
N's demo or right after.

## 2. Read mechanically, in plan mode

Call EnterPlanMode (not when drafting ahead). Read by rule, not by judgment:

- every decision record the gate names by slug in its Decided and Decide by proof sections
  (`docs/decisions/*-<slug>.md`);
- every open-question slug it names, in `docs/open.md`;
- when a record cites a decision source under `docs/decisions/sources/`, that source's section
  for this gate, which holds the full detail the roadmap summarises;
- then only the standing docs this gate touches (`docs/design.md` for what the product is,
  `docs/tech/architecture.md` for how it is built) and the source files the tasks will change.

Plan to the product, not the instance: if what the gate builds recurs elsewhere in the product
(read `docs/design.md`), fit the layout and data to the broader structure, not only the case in
front of you. Do not read the whole docs tree.

## 3. Draft

Write the draft in this shape:

```
# <gate-slug>

Acceptance: <what the owner does on the running product, and the sentence they can then say>

Supporting (built here though neither the demo nor the acceptance sentence needs it): <item: the
reason it stays in this gate> | none

- [ ] <task>
- [ ] ...
- [ ] Run the demo end to end on the running product, including its Break it: step, draft the
      demo brief into this plan under `## Demo brief`, and fix what the run shows. Stop the dev
      stack and every process it started before the next task.
- [ ] Run /serial-build:red on this gate and fix every red finding it reproduces.

Proof (the commands done will re-run; each must pass before the gate ships):

    <one command per QA line, run from the project root>

Tried to break (the red lane attempts at least these):
- <attack from the gate's Tried to break section>
- <attack the tasks made newly possible: malformed and boundary inputs, a broken neighbour beside
  a valid one, repeated or out-of-order steps, limits, missing dependencies>
- The owner's break step: <the Break it: step from the gate's Demo, as the owner will run it>

Blocking open questions: <slugs, each with what it is> | none

New open questions (written to docs/open.md on approval):
- <slug>: <the question, why it matters, a recommendation> | none
```

Tasks only. Plan mode cannot write files, so a design question that comes up is drafted in the
"New open questions" list (what it is, why it matters, a recommendation) and referenced from the
task by its slug instead of being resolved inline; step 5 writes it to `docs/open.md`.

Steps 2 to 4 never call AskUserQuestion; the owner reads the plan once, at step 5. A "Decide by
proof" item goes to the reviewer in step 4 to measure, and its measured answer is folded in. A
genuine design question goes to the "New open questions" list.

While building, the builder may be blocked for half an hour or more on something outside the
repository (CI, a deploy, an account the owner must create). Then a partial red run on the slices
already finished uses the wait (`/serial-build:red`, "When to run"), instead of finished code
waiting hours to be attacked.

The demo task sits before the red task on purpose. Running the demo is what finds the bugs that
stop a demo (a command that does not start, a stale pid file, a refusal that is not an error), and
fixing them before red means the red lane attacks code that has already survived a real run.
After red is clear, `/serial-build:demo-brief` re-runs only the brief's commands to refresh its
facts. The demo cannot run while the red lane runs: the dev stack writes ignored files the red
guard watches, which would void the run. Every QA
line in the gate becomes a task and a command in the Proof block, because the ship-gate script
runs those commands before the gate can ship and `docs/done.md` re-runs them at every handoff.
Use `Manual:` followed by the steps only for what no command can show. A proof command that changes the tree on
purpose (a planted-violation check) undoes the change before it exits, pass or fail (a `trap` on
exit), so a later command and the end-of-turn stop check see the tree as it was; the handoff's
proof run names one that does not.

## 4. Adversarial review, on every draft

Do not call ExitPlanMode on the first draft, and not on the folded one either. Launch the
`serial-build:adversarial-reviewer` agent with: the draft's path or text, the gate's roadmap
section, the decision records and open questions it names, the source files the tasks touch, and
three to five attack questions specific to this gate (what would make it fail its own QA, what
contradicts a record, what would not build). Tell it it may copy the repository into a scratch
folder and try the risky parts, and must measure rather than assume.

Ask the reviewer one more question for every item the gate builds: does the demo or the
acceptance sentence need this item? An item neither needs (supporting tooling: a consistency
check, a pre-deploy script's error handling, extra startup checks) moves to a later gate, by
default the one whose demo does need it, through the "New open questions" list or a roadmap note
in the draft; or it stays, listed under "Supporting" with the reason it cannot wait. The red lane
attacks the acceptance sentence's surface first and the Supporting items after. In a measured gate
none of nineteen red findings were against the acceptance sentence: all were in tooling the plan
had bundled with it, and the red rounds went there.

Fold in every accepted finding. Then review again with the prior findings listed as already
folded, so the second pass hunts for new ones. Stop after a pass with no major finding (+5), or
after three passes, and say which in one line at the end of the draft. A design choice the
reviewer flags as the owner's to make becomes an open-question slug, not a hedge in the plan.

## 5. Approve and write

Call ExitPlanMode with the folded draft, preceded by at most ten plain lines for the owner: what
the gate builds, how they will run it and try to break it, and each settled decision stated with
its consequence. When the owner approves, write the approved draft verbatim to `docs/plan.md`
(the plan-mode file is scratch; `docs/plan.md` is what the next session reads), add each new open
question to `docs/open.md` under its slug, and run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-canon.sh"`, fixing each FAIL.
Commit it per the project's commit policy, as "Plan: <gate-slug>, <what it builds>".

Then name the next step in one line, to run after `/clear` or in a new session, since the plan
holds everything the builder needs: "next: `/clear`, then build `docs/plan.md`".

## When the gate ships

A gate is done when the owner has run its demo, including its break step, and said its acceptance
sentence; a report, a test, or a green check never accepts it. `/serial-build:handoff` ships it
through the ship-gate script, which refuses while the red lane's record is not clear or a proof
fails, then writes the done entry, removes the gate from the roadmap, and deletes `docs/plan.md`.
