---
name: advance
description: Start the driver, which runs every step of the gate loop that needs no product owner (writing out the next gate, drafting its plan, building, the red lane, the demo brief's refresh), each in a fresh headless session, and stops when the owner is needed. Use when the owner asks to advance the work, run the loop, or build unattended.
argument-hint: Optional --max-steps N, or --dry-run to see the first step only
disable-model-invocation: true
---

Arguments: "$ARGUMENTS" (empty means run until the owner is needed).

The owner starts the driver; a session never starts it on its own judgement. It exists because
most of the waiting in the loop was the owner typing `/clear` and the next command, not deciding
anything. Each step it runs is its own headless Claude Code process, so each starts with a fresh
context and reads where the work stands from the ledger.

## 1. Say what will run

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/advance.sh" --dry-run` from the project root and tell the
owner, in one line, the step it names and why. If it stops for the owner at once, say what it
needs from them and end: there is nothing to run.

## 2. Start it

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/advance.sh" $ARGUMENTS` in the background (it can run for
hours), and wait for it; never run a second one for the same project. A headless session cannot
answer a permission prompt, so if the owner has not set `SB_CLAUDE_ARGS` (the extra arguments
every headless run gets), say so before starting, and name the usual choice,
`--permission-mode acceptEdits --permission-prompts none`, without choosing it for them.

It stops when:

- **the owner is needed** (exit 2): a plan to approve, a question a builder parked, a demo to
  run, or a build that changed what only the owner decides (the approved plan beyond ticking, a
  decision record, an open question, the glossary, the design, the roadmap). Its last lines hold
  the question or name the files. Put it to the owner as it is written, consequence first;
- **nothing is left to run** (exit 0);
- **a step made no progress, a session failed, or the step limit was reached** (exit 1). It names
  the log of the step that stopped it. Read that log's end and tell the owner what happened in
  two or three lines; never restart the driver to retry a step that just failed.

## 3. When the owner answers

- A parked question: record their words with
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/next-step.sh" answer "<their words, verbatim>"`, which commits
  them, then start the driver again only if they ask.
- A plan to approve: `/serial-build:gate`, in this session or a fresh one.
- A demo to run: the brief is under `## Demo brief` in `docs/plan.md`. When they say the
  acceptance sentence, run `/serial-build:handoff` in this session.

Next, when the driver stopped for the owner: the one thing it needs from them, as a question
they can answer in a sentence.
