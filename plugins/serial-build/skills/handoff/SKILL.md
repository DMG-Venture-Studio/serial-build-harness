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

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/run-proofs.sh"` from the project root and quote its output.
It runs every command under `Proof:` in `docs/done.md` exactly as written, and reports a `Manual:`
entry as "manual, not re-run". Never run the proofs one by one instead: the script holds a marker
while it runs, so the end-of-turn stop check does not test a tree a proof has half-changed on
purpose (a planted-violation proof undoes its change only at its end). If it may outlast the
tool's timeout, run it in the background and wait for it; it exits 3 while another proof run is
live. A proof it says left the tree changed is a broken proof: undo what it left and file the fix
through `/serial-build:intake`. A proof that fails moves its gate back to the top of the roadmap as
a regression gate. `docs/done.md`
is never hand-edited (a hook refuses it); run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --regress <gate-slug> --failed "<the failing output>"`.
Nothing stays in done on faith.

A proof that no longer earns its re-run at every handoff (one another proof line already runs,
such as a single test file the suite runs; or one the project moved to a weekly schedule) is
retired, never skipped:
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" --retire-proof <gate-slug> "<command, exactly as listed>" --decision <slug> --owner-said "<their words, verbatim>"`.
It is the owner's call, so ask them first. It needs a committed, dated decision record saying why
(file it through `/serial-build:intake` first) that names every test file the command runs, so a
red finding's test is retired only where the record says what still runs it. It refuses a gate's
last proof and a proof that fails now: a failing proof is a regression, never a retirement. It
commits the change itself.

## 2. The red lane's verdict

If `docs/plan.md` exists, run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/red-status.sh"` and quote its
output. It checks that the red record is credible (every attempt listed, the raw output filed)
and runs each finding's reproduce command against the test exactly as the red lane wrote it.
It remembers its verdict for the exact tree, so asking again on an unchanged tree answers at once;
pass `--fresh` only after a change git cannot see, such as a reinstalled dependency folder.
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
which in one line, as the command to run after `/clear` or in a new session, for example "next:
`/clear`, then `/serial-build:gate`". The ledger holds everything a cold start needs, so the next
session never inherits this one's context. Other plugins also ship a skill named handoff; always
name this one in full, `/serial-build:handoff`, when telling the owner what to run.

When a gate shipped and the next written-out roadmap gate has no draft
(`sh "${CLAUDE_PLUGIN_ROOT}/scripts/plan-draft.sh" status <next-gate>` exits 1), start drafting it
now, without asking:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/plan-draft.sh" start <next-gate>
```

and run the launch command it prints, which starts `/serial-build:gate --draft <next-gate>` in the
background from a worktree outside the project. Always keep its descriptive `--name`; it is what
the job list shows. Asking first buys nothing: the draft session writes only to its own branch,
and the owner approves the plan when `/serial-build:gate` takes the draft, exactly as for a plan
made from scratch. If a draft is already saved, the next command is `/serial-build:gate`, which
takes it.

When a gate shipped and `docs/roadmap.md` has items under `## Tooling fixes`, or the branch
`serial-build/tooling-fix` waits to merge, name `/serial-build:tooling-fix` too: with no gate
active it can merge now.

Never launch a background session that builds; the owner supervises building.

## What stays out

- **No duplication.** Cite records by slug; never restate them. A summary that restates the
  architecture doc goes stale against it.
- **No secrets.** Name a credential and where it lives, never its value.
- **No handoff file.** Everything durable is already in the ledger, the open questions, or a
  decision record. If it is not, put it there.
