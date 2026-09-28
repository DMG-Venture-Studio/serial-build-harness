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
4. Define every term where it first appears in the brief, even ones used earlier in the session.
   Consequence before mechanism. No emojis.

## After the owner answers

Their words go into `docs/done.md` as the gate's `Accepted:` line, verbatim, when the handoff
moves the gate; into `docs/plan.md` as an "Ask first:" line until then. If their answer raises a
question, it becomes an open question through `/serial-build:intake`. If their break step broke
it, that is a red finding: write the failing test through `/serial-build:red`. Never paraphrase a
verdict into a stronger claim than the owner made.
