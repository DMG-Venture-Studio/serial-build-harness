---
name: handoff
description: Close a session so a fresh agent picks up the work at once. Re-runs every proof in docs/done.md, refuses to move a gate while a red finding still reproduces, moves an accepted gate to done, and records state in the gate ledger. Use at the end of a working session or when the product owner has accepted a gate.
argument-hint: What the next session will be used for
disable-model-invocation: true
---

Focus for the next session: "$ARGUMENTS" (empty means continue the current work).

Close this session so a fresh agent can continue without re-reading it. State lives in the gate
ledger (`docs/roadmap.md`, `docs/plan.md`, `docs/done.md`) and in `docs/open.md`; there is no
handoff file. The product owner is `owner.name` in `.claude/serial-build.json`.

## 1. Audit every proof

Read `docs/done.md`. For every entry, run each command under `Proof:` exactly as written, from the
project root; a `Manual:` entry is reported as "manual, not re-run". Report every result. A proof
that fails moves its gate back to the top of the roadmap as a regression gate. `docs/done.md`
is never hand-edited (a hook refuses it); run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --regress <gate-slug> --failed "<the failing output>"`.
Nothing stays in done on faith.

## 2. The red lane's verdict

If `docs/plan.md` exists, run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh"` and quote its
output. It checks that the red record is credible (every attempt listed, the raw output filed)
and runs each finding's reproduce command against the test exactly as the red lane wrote it.
Exit 1 means the gate does not ship this session: either there is no credible red run (run
`/serial-build:red`), or a finding is open (the builder fixes the code; deleting, weakening, or
editing a red test or its line reopens the finding rather than resolving it; a finding the owner
judges wrong is demoted only with `ship-gate.sh --demote`, and a test a fix had to change is
re-pinned only through `/serial-build:red`). Say which, in one line, consequence first.

## 3. Ship or record state

- **Ship the gate only when the owner ran its demo on the running product this session,
  including its break step, and said its acceptance sentence.** Then run:

  ```
  sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" <gate-slug> --accepted "<the owner's words, verbatim>"
  ```

  The script decides, not you: it refuses unless the red record is clear and every proof in the
  plan passes now. On success it writes the done entry (date, proof commands plus each red
  finding's reproduce command, what the red lane tried, the owner's words), removes the gate from
  the roadmap, deletes `docs/plan.md`, lists unticked tasks, and runs the canon check. File each
  still-relevant unticked task as a roadmap gate through `/serial-build:intake`, and fix any FAIL.
  If it refuses, quote why and stop; never work around it. It exits 0 once the gate has shipped,
  even if the canon check it runs afterwards fails; never run it twice for one gate.
- Otherwise, if `docs/plan.md` exists, tick its checkboxes to match what is actually done. Never
  change its scope or add tasks; a new task is a roadmap gate or an open question, filed through
  `/serial-build:intake`. If the owner has not said the sentence, open the plan with a line
  starting "Ask first:" that says what to ask them and what happens on each answer. A report, a
  test, or a green check never counts as acceptance.
- Anything the owner must be asked before work continues is an open question or an "Ask first:"
  line. Anything this session decided that the docs do not yet say goes through
  `/serial-build:intake`, not written ad hoc.

Commit per the project's commit policy, as "Handoff: <what moved or what waits, in plain words>".

## 4. Hand off

The next action is implicit: `docs/plan.md` if it exists, else `/serial-build:gate` on the first
written-out roadmap gate (or `/serial-build:intake` to write out the next one-line gate). Say
which, in one line. Other plugins also ship a skill named handoff; always name this one in full,
`/serial-build:handoff`, when telling the owner what to run.

When the next session starts immediately, offer to launch it in the background, seeded with the
active plan, and ask before launching; a background agent that starts work the owner meant to
supervise is worse than none:

```
claude --bg --name "<descriptive name>" "$(cat docs/plan.md)"
```

Without a plan, seed it with the first gate's heading and acceptance and the instruction to run
`/serial-build:gate`. Always pass a descriptive `--name`; it is what the job list shows.

## What stays out

- **No duplication.** Cite records by slug; never restate them. A summary that restates the
  architecture doc goes stale against it.
- **No secrets.** Name a credential and where it lives, never its value.
- **No handoff file.** Everything durable is already in the ledger, the open questions, or a
  decision record. If it is not, put it there.
