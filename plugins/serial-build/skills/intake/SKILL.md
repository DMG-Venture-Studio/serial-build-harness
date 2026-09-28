---
name: intake
description: Slot a new finding, idea, bug, requirement, or pasted brief into a serial-build project's docs without editing the plan or the standing docs ad hoc. Use whenever something new turns up mid-work - a bug, an idea, a review's findings, a handoff from another session.
argument-hint: The finding in a sentence or two, or a pasted brief
---

Finding: $ARGUMENTS

Slot the finding into the project without mutating the standing docs ad hoc. The product owner
is `owner.name` in `.claude/serial-build.json`; they approve from a summary, never a diff.

## 1. Keep the source

If the input is more than a sentence or two (a brief, a review's findings, another session's
handoff), file it verbatim first under `docs/decisions/sources/<slug>-<YYYY-MM-DD>.md`, with a
short header saying what it is, who wrote it, and which records act on it. Strip only secrets and
scratch paths; change nothing else. The records you write cite it by slug; nobody has to trust a
paraphrase.

## 2. Read only what it touches

Read `docs/roadmap.md`, `docs/open.md`, and only the standing docs and decision records the
finding touches (`docs/design.md`, `docs/tech/architecture.md`, the named records). Not the whole
tree. Never `docs/plan.md` for editing: see step 5.

## 3. Classify it as exactly one

a. **New work, consistent with the docs**: draft a roadmap gate with every section (Builds, Demo
   ending in a `Break it:` step where the owner tries to break it, Depends on, Decided, Decide by
   proof, Open, QA, Tried to break, Acceptance) and propose where it slots relative to the
   existing gates.
b. **An undecided question**: draft a `docs/open.md` entry under a new slug: the question, why it
   matters, and a recommendation where there is one.
c. **It contradicts the docs**: this is a decision, not intake. Draft the dated decision record
   `docs/decisions/<YYYY-MM-DD>-<slug>.md` (Date line; Decided, each point consequence first;
   Rejected, with why; Reopens if) plus the smallest current-state edits to the affected standing
   docs. Do not soften the contradiction into a gate.
d. **A regression** (a proof in `docs/done.md` no longer passes): move that gate back to the top
   of the roadmap with
   `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --regress <gate-slug> --failed "<the failing output>"`.
   It files the failing output as a decision source and writes a regression gate with every
   section; `docs/done.md` is never edited by hand.
e. **Writing out a later gate** (the next one-line gate in a roadmap stage's Later list is about
   to be planned): replace its line with the gate written out with every section, as in a, keeping
   its slug and its place in the order.

Write every sentence for someone who has never opened the repository: say what each thing is and
what changes for it, expand every handle into the concrete thing, cite records as See `slug`. No
dates, statuses, or rejected alternatives outside `docs/decisions/`.

## 4. Check, review, summarise; then stop

Never show a diff. Write the files, then, before any commit:

1. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-canon.sh"` and report each line PASS or FAIL. Also
   check by reading: no term the change retired remains anywhere; no file now holds a second
   role. A failure is fixed and rerun before going on. Name every glossary entry the NOTE line
   lists, individually, for the owner's approval.
2. When a source was filed in step 1, launch the `serial-build:adversarial-reviewer` agent in
   source-review mode: give it the source's path and the list of files written, and ask what the
   source says that the files miss, contradict, or weaken. Fold in what it finds and rerun the
   checks.
3. Give the owner a plain summary of at most ten lines: what changed, what was superseded, and
   what you decided that the source did not cover, each decision with its consequence.

Stop the turn on the summary and wait. Commit on approval, per the project's commit policy, as
"Intake: <what changed, in plain words>".

## 5. The active plan is not intake's

Never edit `docs/plan.md`. A mid-flight finding queues behind the active gate as a roadmap gate or
an open question. If it blocks the active gate, say so, and let the owner decide whether to
re-plan with `/serial-build:gate`.
