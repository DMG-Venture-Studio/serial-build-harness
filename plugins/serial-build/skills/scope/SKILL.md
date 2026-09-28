---
name: scope
description: Interview the product owner and scaffold a project for the serial-build loop - vision, first demo, floors, stack, where things live, the docs ledger, rules, and the hook config. Use on a new or unscaffolded repository when the user asks to scope, set up, or start a project with serial-build.
argument-hint: Optional one-line pitch of what is being built
disable-model-invocation: true
---

Pitch, if given: $ARGUMENTS

Turn the product owner's intent into a scaffolded project: a vision they recognise, a first gate
they can run, a layout with one job per folder, and the config that switches the plugin's hooks
on. The owner approves from what they can read, a proposed tree and a short summary, never from
a diff. Nothing is written until they say so, and no existing file is replaced unless they name it.

Scripts live under `${CLAUDE_PLUGIN_ROOT}`. Run them with `sh` from the project root.

## 1. Read the room

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/detect-state.sh"`. Branch on its `state:` line:

- **greenfield**: nothing but a licence, a readme, or a .gitignore. Go on to the interview.
- **existing**: other files are present. Read the manifest files and the readme it lists
  (package.json, pyproject.toml, go.mod, Cargo.toml, build.gradle, and similar) so the interview
  can offer what is already there as the default answers. Then ask with AskUserQuestion whether to
  scaffold the harness here, stating that no existing file is overwritten without being named.
  Options: "Scaffold alongside what is here" and "Stop". Stop means stop.
- **scoped**: `.claude/serial-build.json` exists. Say the project is already set up, run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-config.sh"` and `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-canon.sh"`,
  report both, and ask whether to fill only the missing files or stop. To fill them, do not
  interview again: reuse the newest `docs/decisions/sources/scoping-answers-*.json` and the
  existing config, and go straight to step 5's dry run with
  `--answers <that file> --config .claude/serial-build.json`. Files already present show as
  `same` or `exists, kept`; only missing ones are written. If the render names answers the saved
  file lacks (a newer plugin added a template), ask for exactly those keys and add them to a copy.

If the directory is not a git repository, say that the stop checks and the red lane need one, and
offer to run `git init` as the first write.

## 2. Interview

Ask in rounds of one to four questions with AskUserQuestion. For every question, draft two to
four concrete options from the pitch, the repository, and earlier answers, and mark the one you
recommend. The owner can always pick "Other" and type their own. If there is no pitch at all, ask
for one in a single plain message first: what it is and who it is for, in a few sentences.

One round is deliberately open, asked in a plain message with no options, right after the pitch,
because drafted options would put words in the owner's mouth where their own words matter most:

- What do the people it is for do today instead, and what does that cost them?
- A year from now, what would failure look like?

Keep a verbatim record as you go (the question, the options offered, the answer word for word);
it becomes the scoping record's source.

1. **The product**: who uses it and in what situation; the goals a user would notice; what it
   deliberately is not.
2. **The first slice**: the demo that proves the product exists. It is something the owner does
   on the running product and sees, not a test passing. Draft options as "you do X and see Y".
   Also draft the owner's break step for it, one thing they do to try to break it, modelled on:
   feed it a valid input beside a deliberately broken sibling input and confirm only the broken
   one is refused, naming what is wrong.
3. **The owner**: their name (offer the git author name that detect-state printed) and how they
   want to be written to. Offer "Plain language, every term defined where it is used
   (Recommended)", "Terse and technical", and one drafted from how they have written so far.
4. **Constraints**: the floors, the hard rules a session must stop and ask before crossing.
   Draft them from the stack and the pitch (no secrets in the repo, deterministic tests, no
   network in the core logic, and so on); multiSelect.
5. **Stack and deployables**: language, framework, storage, and hosting, each with its reason;
   the things that ship and run on their own; multiSelect for the deployables.
6. **Working agreements**: whether to commit finished, proven work without asking; the inbox
   folder name (`claude_outputs` unless they want another); which hooks to turn on (guard generated
   files, lint on edit, tests at stop, the inbox), all on by default.

## 3. Read the vision back

Before any layout, read the vision back in five plain lines: what it is; who it is for and what
they do today instead; the first demo and its break step; what it is not; what failure would
look like. Ask with AskUserQuestion: "Is this it?" with "Yes, that is it", "Close; let me
correct it", and "No, start over". Fold corrections and read it back again until the answer is
yes. Everything after this builds on these five lines.

Then draft the rest of the roadmap: three to six later gates, one line each, in the order they
would ship, under stage headings, each something the owner will be able to do. Only the first
gate is written out in full; intake writes out each later one before it is planned. Show the
list and let the owner reorder or cut it.

## 4. Propose where things live

From the answers, propose the layout and show it as a table before any file exists:

- **Roots, one job each.** One top-level folder per deployable or per kind of source, following
  the ecosystem's own conventions (a Python package under `src/`, a web app's `app/`, and so on).
  For each root say what it holds and what it never holds. No root for convenience; a new
  top-level folder needs a deployable.
- **Tests beside the code they test**, in the ecosystem's convention (pytest `tests/`, Go's
  `_test.go` files, a `Tests/` target), never a repository-wide tests folder for convenience.
- **Generated files**: each one with its source and the command that regenerates it, and
  whether it is committed (only when a fresh checkout cannot run without it).
- **Commands**: the test, lint, build, and generator commands, and which hook runs each.
- **The red lane's test paths**: the patterns the red-breaker agent may write, which must cover
  every test folder and nothing else.
- **What the tests need in an isolated checkout**: the red lane's agent works in a git worktree,
  which has no ignored files. Name the dependency folders to link into it (`node_modules`,
  `.venv`), which become `worktree.symlinkDirectories` in `.claude/settings.json`, and the small
  ignored files to copy (`.env`, a generated config), which go in `.worktreeinclude`. The scaffold
  also sets `worktree.baseRef` to `"head"`, so the worktree starts from the gate's own commits.

Ask with AskUserQuestion: "Use this layout?" with "Use it (Recommended)", "Change roots", and
"Change commands". Fold changes and ask again until accepted.

## 5. Write the answers and the config, then show the tree

Create a scratch folder with `mktemp -d` and write two files there, not in the project:

- `answers.json`: every key listed in `${CLAUDE_PLUGIN_ROOT}/skills/scope/references/answers.md`,
  read that file first. The first gate's Demo ends with its `Break it:` step, and its Tried to
  break line lists what the red lane must attempt.
- `serial-build.json`: the hook config, per `${CLAUDE_PLUGIN_ROOT}/skills/scope/references/config.md`.
  Include `owner.name`, `inbox`, the generated files, the on-edit and on-stop checks for the hooks
  the owner turned on, and `red.test_paths`.

Then run the dry run:

```
sh "${CLAUDE_PLUGIN_ROOT}/skills/scope/scripts/render.sh" --answers <scratch>/answers.json --config <scratch>/serial-build.json --dry-run
```

It prints the tree, each file marked `new`, `same`, `append N lines` (a .gitignore merge),
`append marked section` (an existing CLAUDE.md gains this project's section at its end, marked
so it is appended once), `merge worktree settings` (an existing `.claude/settings.json` gains the
`worktree` block and keeps everything else), or `exists, kept` (with a note when a setting must be
added by hand; do it with the Edit tool after the write). The harness's own rules go to
`.claude/rules/serial-build.md`, which loads in every session, so they apply even where the
existing CLAUDE.md stays as it was. A missing answer fails naming the key; add it and rerun. Show the owner the
tree as printed, and in at most ten plain lines: what the product is, the first gate and its
demo, the later gates, the layout, which hooks will run what, and the five glossary entries the
scaffold adds (acceptance, gate, red finding, red lane, slug), each named for their approval.

Ask with AskUserQuestion: "Write these files?" with "Write them", "Change something", "Cancel".
If files are marked `exists, kept`, ask a separate multiSelect question listing each one by path,
"Replace these existing files?", where selecting none is the default. Only files the owner
selects go to `--overwrite`.

## 6. Write, check, and hand over

Run the same render command without `--dry-run`, adding `--overwrite <path>` for each file the
owner selected. Then run, from the project root:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-config.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-canon.sh"
```

A FAIL is fixed in the files and rerun before reporting. Delete the scratch folder; the answers
are kept in the scoping record as `scoping-answers-<date>.json`. Commit if the
owner's commit policy says to, with a message such as "Scope: <project>, the first gate
<slug>, and the serial-build ledger".

Report consequence first: what now exists, what the hooks will do (they read the config on every
call, so they are live from the next tool call, no restart), and the next step, which is
`/serial-build:gate` to plan the first gate.
