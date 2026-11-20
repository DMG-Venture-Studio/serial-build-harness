---
name: demo-brief
description: Write the instructions the product owner follows to run a gate's demo, including the step where they try to break it, with every fact computed from the project rather than remembered. Use when a gate is built and red-checked and the owner is about to run its demo.
argument-hint: Optional gate slug, default the gate in docs/plan.md
---

Gate asked for: "$ARGUMENTS" (empty means the gate in docs/plan.md, else the first roadmap gate).

The product owner (`owner.name` in `.claude/serial-build.json`) judges every gate; the agent never
does. A brief that tells them the wrong thing to expect is worse than no brief, so every fact in
it (a URL, a command, an input, an expected output, a count) comes from running something or
reading the project's data now, not from memory of the session.

## When it runs

Twice per gate, and the second run is cheap:

- **Draft, before red.** The plan's demo task (it sits before the red task) runs the demo end to
  end, writes the brief under `## Demo brief` in `docs/plan.md`, and fixes what the run shows.
  This is where the bugs that stop a demo surface, while fixing them still costs one commit and
  not another red round. Stop the dev stack and every process it started afterwards: the red
  guard watches ignored files, and a daemon still writing into the project voids the red run.
- **Refresh, after red is clear.** Re-run only the commands the drafted brief states, so every
  fact is computed now, and update any fact that moved. The brief the owner reads is this
  refreshed one. If there is no drafted brief, do the steps below in full. End the refresh with
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/next-step.sh" mark-brief`, which records in the brief the
  commit it was refreshed on (it refuses while the red record is not clear or the gate's work is
  not committed), then commit the plan. That line is how the ledger shows the gate is ready for
  the owner; the brief counts as fresh until a file outside `docs/` changes.

In `docs/plan.md` the brief goes after the plan's top block and before `## Red`. No line of it
starts with `Proof`, `Manual:`, `Tried to break`, or `Acceptance:`; those lines belong to the top
block, which the scripts read.

## Steps

1. Read the gate's Demo, Tried to break, and Acceptance from `docs/plan.md` or
   `docs/roadmap.md`, and only the decision records the gate names.
2. Gather each fact the brief states by running the command or reading the file that holds it:
   how to start the product, the exact inputs, what the product prints or shows for them. When a
   fact cannot be computed, say so in the brief rather than guessing.
3. Write the brief in this shape, and nothing else:
   - **What to do**: numbered steps, from a fresh start to the end of the demo.
   - **What to look for**: one bullet per thing the gate is about, what a pass looks like and what
     a failure looks like.
   - **Try to break it**: the gate's Break it: step, as numbered actions, and what a correct
     refusal looks like (the broken input refused, naming what is wrong; the valid one beside it
     accepted).
   - **What to report back**: the two to four observations the acceptance sentence needs, as
     questions the owner can answer in a sentence each.
   - **Choices the build made**: every behaviour the owner will meet that neither the plan nor a
     decision record it names states (a default, a name, a message, a limit, what happens on a
     bad input), one line each, with what was chosen. Find them by reading the diff since the
     plan was committed, not from memory; write "none" when there are none. A builder that runs
     unattended is told to ask rather than choose, and this list is where a choice it made anyway
     reaches the owner before they accept.
4. Define every term where it first appears in the brief, even ones used earlier in the session.
   Consequence before mechanism. No emojis.

## After the owner answers

Their words go into `docs/done.md` as the gate's `Accepted:` line, verbatim, when the handoff
moves the gate; into `docs/plan.md` as an "Ask first:" line until then. If their answer raises a
question, it becomes an open question through `/serial-build:intake`. If their break step broke
it, that is a red finding: write the failing test through `/serial-build:red`. Never paraphrase a
verdict into a stronger claim than the owner made.

## Next

After the refresh, the owner runs the demo. When they say the acceptance sentence in this
session, run `/serial-build:handoff` yourself, at once; never hand them the command to type. The
owner's acceptance words are in this session, and handoff ships only on words the owner said in
the session that runs it. This is the one step that does not start fresh, and the session is
small, since it began at the refresh. If they do not say it, or their break step broke it, follow
"After the owner answers" above and do not run the handoff.

With no owner in the session (the driver ran this skill headless), end after the refresh and its
mark: the driver reads the ledger, stops, and tells the owner the demo is ready.
