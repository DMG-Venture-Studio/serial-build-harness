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
exists, stop and ask whether to finish, regenerate, or retire it first. There is never more than
one active plan.

## 2. Read mechanically, in plan mode

Call EnterPlanMode. Read by rule, not by judgment:

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

- [ ] <task>
- [ ] ...
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
task by its slug instead of being resolved inline; step 5 writes it to `docs/open.md`. Every QA
line in the gate becomes a task and a command in the Proof block, because the ship-gate script
runs those commands before the gate can ship and `docs/done.md` re-runs them at every handoff.
Use `Manual:` followed by the steps only for what no command can show.

## 4. Adversarial review, on every draft

Do not call ExitPlanMode on the first draft, and not on the folded one either. Launch the
`serial-build:adversarial-reviewer` agent with: the draft's path or text, the gate's roadmap
section, the decision records and open questions it names, the source files the tasks touch, and
three to five attack questions specific to this gate (what would make it fail its own QA, what
contradicts a record, what would not build). Tell it it may copy the repository into a scratch
folder and try the risky parts, and must measure rather than assume.

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

## When the gate ships

A gate is done when the owner has run its demo, including its break step, and said its acceptance
sentence; a report, a test, or a green check never accepts it. `/serial-build:handoff` ships it
through the ship-gate script, which refuses while the red lane's record is not clear or a proof
fails, then writes the done entry, removes the gate from the roadmap, and deletes `docs/plan.md`.
