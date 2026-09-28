# serial-build

A Claude Code plugin for building a product one small, demonstrable slice at a time. A slice
counts as done only when the product owner has run it themselves, and only after a separate agent
has tried to break it.

Without a harness like this, an agent building a product tends to drift. Plans get edited mid
flight, findings get patched straight into whatever doc is open, "done" means "the tests the
builder wrote pass", and the next session re-derives where things stand from a long chat. This
plugin makes those failure modes hard to fall into:

- **Work moves through one ledger of gates.** A gate is one slice the owner can run and judge. It
  names what it builds, the demo that shows it, what an attacker must try in order to break it,
  and the sentence the owner can say once it works. Gates wait in a roadmap, one is in flight in a
  plan, and shipped ones sit in a done file with commands that prove they still work.
- **Only the owner accepts a gate, and code records it.** No report, test, or green check moves a
  gate to done. The owner runs the demo, including one step where they try to break it, and says
  the sentence. A script then writes the done entry, and refuses to if any proof fails or the
  attacker's findings are not fixed. A hook refuses the agent's Edit and Write calls on the done
  file, and each entry carries a checksum the docs check verifies, so an entry changed any other
  way is reported.
- **Every gate is attacked before it ships.** A fresh agent that did not build the gate tries to
  make it fail from its own isolated copy of the repository. Only tests come back from that copy,
  and a gate with a failure it reproduced cannot ship until that exact test passes.
- **Nothing is edited ad hoc.** New findings go through an intake step that files them as a gate,
  an open question, or a dated decision, and checks the docs mechanically before asking the owner.

It came out of a real project that built its process as it went. This is that process with the
project's domain stripped out, so a new project can start with it on day one.

## Install

From GitHub, in Claude Code:

```
/plugin marketplace add DMG-Venture-Studio/serial-build-harness
/plugin install serial-build@serial-build-harness
```

From a local clone (before it is pushed, or to try a change):

```
/plugin marketplace add /path/to/serial-build-harness
/plugin install serial-build@serial-build-harness
```

The same commands work from a shell as `claude plugin marketplace add ...` and
`claude plugin install ...`. Add `--scope project` to install for one repository only.

Installing it user-wide is safe for other repositories. In any project without a
`.claude/serial-build.json` file (the per-project config, described below), every hook exits at
once and silently. The one exception is the fence around the plugin's own red-breaker agent,
which acts on nothing else.

Then, in a new or existing repository, run `/serial-build:scope`. The short names (`/scope`,
`/gate`, and so on) also work, but only while no other plugin or project uses the same name.
Several other plugins ship a skill called `handoff`, so when names collide use the full
`/serial-build:handoff`.

## The loop

```
/scope  ->  /gate  ->  build  ->  /red  ->  owner runs the demo  ->  /handoff
                ^                                                       |
                +--------------------- next gate ----------------------+

/intake  any time something new turns up
```

1. **Scope** (`/serial-build:scope`, once): an interview that turns the owner's intent into a
   project. It covers what the product is, who uses it and what they do today instead, what
   failure would look like, the first demo, the hard constraints, the stack, and where things
   live. It reads the vision back for the owner to confirm, then writes the docs, the rules, and
   the config.
2. **Gate** (`/serial-build:gate`): plans the first roadmap gate on Claude Code's plan mode. An
   adversarial reviewer attacks every draft before the owner sees it.
3. **Build**: the session works through the plan. Hooks refuse edits to generated files, lint
   each edit, and run the tests before the session can end its turn on new, uncommitted changes.
4. **Red** (`/serial-build:red`): a fresh agent tries to break the gate. What it breaks comes back
   as a failing test, and the builder fixes the code until it passes.
5. **Demo** (`/serial-build:demo-brief`, then the owner): the owner runs the demo, tries to break
   it, and says the acceptance sentence, or does not.
6. **Handoff** (`/serial-build:handoff`): re-runs every proof in done, then ships the accepted
   gate through the ship-gate script, which refuses while a red finding is open or a proof fails.

**Intake** (`/serial-build:intake <finding>`) runs whenever a bug, idea, review, or handoff from
another session arrives. It never edits the active plan; findings queue behind it.

## What is in the plugin

### Skills (slash commands)

| Skill | What it does | What breaks without it |
|---|---|---|
| `/serial-build:scope` | Detects whether the repository is empty, already has work, or is already set up. Asks one open round in the owner's own words, then multiple-choice rounds it drafts from the pitch. Reads the vision back in five lines for confirmation, and drafts the first gate in full plus three to six later ones in a line each. Shows the file tree it would write, each file marked new, same, append, or kept, and writes only after a yes. It never replaces an existing file the owner did not name. An existing CLAUDE.md gains a marked section once. Re-running it fills missing files from the saved answers without asking again. | A new project starts with no shared definition of done, no first demo, and a layout decided by whichever session got there first. |
| `/serial-build:gate` | Plans one gate. It reads only the decision records and open questions the gate names, and drafts tasks, a Proof block, and a "tried to break" list. It runs the adversarial reviewer on every draft (at least twice) and writes `docs/plan.md` and any new open questions on approval. | Plans carry opinions and estimates instead of tasks, contradict earlier decisions, and reach the owner with build-stopping problems a reviewer would have caught. |
| `/serial-build:intake` | Files a finding as exactly one thing: a new gate, an open question, a dated decision record, a regression, or the full write-up of the next one-line gate. Long inputs are kept verbatim as decision sources. It runs the mechanical canon checks and a reviewer against the source, and gives the owner a summary of ten lines or fewer instead of a diff. | Findings get patched into whatever doc is open, facts drift between copies, and the owner is asked to approve diffs nobody can read. |
| `/serial-build:red` | Snapshots the project, sends the red-breaker agent at the active gate in its own git worktree with only what is on disk, and verifies nothing outside it changed. Brings back only test files, files the agent's raw output, re-runs each finding itself, and records the findings in the plan. | Gates are proven green by the session that built them, which covers only the scenario it wrote the checks for. |
| `/serial-build:demo-brief` | Writes the owner's instructions for running the demo: what to do, what to look for, how to try to break it, and what to report back. Every fact comes from running something now, not from memory. | The owner runs the wrong thing or is told to expect the wrong result, and a pass means nothing. |
| `/serial-build:handoff` | Re-runs every proof in done, moving a gate whose proof fails back to the roadmap. Checks the red lane's record and ships an accepted gate through the ship-gate script. Offers to start the next session in the background. | "Done" stays done on faith, and the next session re-reads the whole chat to find out where things are. |

### Agents

| Agent | What it does | What breaks without it |
|---|---|---|
| `adversarial-reviewer` | Runs on Opus with read-only tools plus a shell, so it can copy the repository to a scratch folder and try the risky parts. It scores each finding: +2 minor, +5 major (the draft would fail its own checks, contradict a decision record, or not build), or +10 major improvement (it removes a class of problems). Each finding carries file:line evidence and replacement wording, and the review ends with a total and a verdict. On a second pass it is given the first pass's findings as already folded, so it hunts for new ones. | In the source project, a first draft that looked complete had four build stoppers, and a second review of an already-fixed draft found five more. |
| `red-breaker` | The red lane's attacker. It did not build the gate and trusts no claim that it works. It attacks neighbours (a valid input beside a broken one), boundaries, order and repetition, the environment, and the acceptance sentence taken literally. It returns failing tests with the command that reproduces each one, or "nothing found" with every attempt listed, and never writes the fix. | See `/serial-build:red`. |

### Hooks

Each hook is a POSIX shell script. Each reads `.claude/serial-build.json` on every call, so a
config change takes effect on the next tool call with no restart. Each exits 0 silently when that
file is absent. The project may be the whole repository or a subfolder of a larger one.

| Hook | When | What it does | What breaks without it |
|---|---|---|---|
| `guard-generated` | Before any edit or write | Refuses an edit to a file listed under `generated` and names the command that regenerates it. Also refuses Edit and Write calls on `docs/done.md`, which only the ship-gate script writes (a shell write is not seen here; the checksum on each entry catches it). Exit 2, so the session sees the reason. | A hand edit to a generated file is silently lost on the next regeneration, and "done" could be declared by whichever session holds the pen. |
| `red-fence` | Before any edit, write, or shell command | Acts only when the caller is the red-breaker agent: it refuses writes outside `red.test_paths` (measured from the project's place in the agent's worktree) and any git command, where git is the command being run, that is not read-only (`status`, `diff`, `log`, `stash list`, `branch --show-current`, `worktree list`, and the like). It is advisory, an early stop for obvious attempts; the red lane's guarantee is the worktree isolation and the checks after the run (see below). | The agent wastes its run on changes that would void it anyway. |
| `edit-checks` | After an edit or write | Runs each `checks.on_edit` rule whose paths match the edited file, such as lint, a format check, or a generator's drift check. The edited path is passed in `SB_FILE`, and a failure is fed back to the session. | A violation surfaces in review, far from the edit that caused it. |
| `stop-checks` | When the session ends its turn | Runs each `checks.on_stop` rule (usually the tests) when git shows uncommitted changes under its paths. It remembers the result for that exact set of changed files, pass or fail, so it never runs twice on an unchanged tree. A failure keeps the session working once; ending the turn again on the same files is allowed, and the next session is told at start. It never loops, and stays fast with thousands of untracked files. | A session ends its turn on red tests it caused, and the next one inherits them. |
| `inbox-touch`, `inbox-stop` | After a tool names the inbox; when the session ends its turn | The inbox is a folder other sessions and tools drop files into, `claude_outputs/` by default, never committed. A session that touched it cannot end its turn while it still holds items; each must be moved to its home or deleted. It nags once per distinct listing and never loops. | The inbox becomes a second, unreviewed docs tree. |
| `session-start` | Session start | Tells the new session the active gate, or the next one to plan or write out; anything the plan says to ask first; and what waits in the inbox. It also reports a config that does not parse, which would otherwise switch every hook off without a word. | Each session re-derives where the work stands. |

Hook state (inbox markers, the fingerprint of the last test run, the red lane's snapshot) lives in
the system temp folder, keyed by project, never in your repository. A reboot costs one re-run of
the tests.

### Scripts the skills call

All live in the plugin's `scripts/` folder and run from the project root with `sh`.

| Script | What it does |
|---|---|
| `ship-gate.sh` | The only writer of `docs/done.md`. `ship-gate.sh <gate> --accepted "<owner's words>"` refuses unless the plan is that gate's, the red record is clear, and every proof passes now. It then writes the done entry with its checksum, removes the gate from the roadmap, and deletes the plan. `--regress <gate> --failed "<output>"` moves a shipped gate whose proof fails back to the top of the roadmap. `--demote <red-slug> --owner-said "<words>"` records, in its own commit, the owner's judgement that a red finding is not a real failure. |
| `red-status.sh` | Whether the red lane's record lets the gate ship (see below). |
| `red-repin.sh` | Re-records a red test that a fix had to change, only if the changed test still fails on the commit from before the fix, in its own commit. |
| `red-guard.sh` | `snapshot` before the red-breaker agent runs; `verify` after, voiding the run if anything but tests changed. |
| `red-import.sh` | Copies only test files back from the red-breaker agent's worktree, voiding the run if it changed anything else there. |
| `check-canon.sh` | The mechanical docs checks: every gate has every section, every reference resolves, no dates or file paths in the standing docs, decision records complete, every done entry as ship-gate wrote it, glossary additions named for approval. |
| `check-config.sh` | Validates a config and says in plain words what each hook will do with it. Run it when a guard seems not to fire. |

## The per-project config: `.claude/serial-build.json`

This one file opts a project in. It sits in `.claude/` beside Claude Code's own project settings,
is committed so every clone gets the same guards, and is plain JSON. The hooks read it with a
small awk parser shipped in the plugin, so no jq or python is needed: jq is not installed on a
stock Mac or Linux, and on a fresh Mac `python3` opens an installer dialog.

```json
{
  "version": 1,
  "owner": { "name": "Ada" },
  "inbox": "claude_outputs",
  "generated": [
    { "path": "api/openapi.gen.ts", "regenerate": "npm run gen:api" }
  ],
  "checks": {
    "on_edit": [
      { "name": "lint", "paths": ["src/**", "tests/**"], "run": "npx eslint --quiet \"$SB_FILE\"" }
    ],
    "on_stop": [
      { "name": "unit tests", "paths": ["src/**", "tests/**"], "run": "npm test --silent" }
    ]
  },
  "red": { "test_paths": ["tests/**"] }
}
```

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Always `1`. |
| `enabled` | no | `false` switches every hook off for this project without deleting the file. |
| `owner.name` | yes | The product owner: the person who runs each demo and whose acceptance sentence ships a gate. Every skill addresses them by this name. |
| `inbox` | no | The inbox folder, relative to the project root. Absent or `""` turns the inbox hooks off. |
| `generated` | no | List of `{path, regenerate}`. An edit to a matching file is refused, naming `regenerate`. |
| `checks.on_edit` | no | List of `{name, paths, run}`. After an edit to a matching file, `run` runs with `sh` from the project root, with `SB_FILE` set to the edited path, so a linter can check just that file. `paths` absent means every file. |
| `checks.on_stop` | no | List of `{name, paths, run}`. At the end of a turn, when git shows uncommitted changes under `paths` that `run` has not yet been run on, `run` runs. Needs a git repository. |
| `red.test_paths` | for the red lane | The files the red-breaker agent may write and bring back. Without it `/serial-build:red` refuses to run, so no gate can ship. |

Patterns are relative to the project root. Only `*` is a wildcard, and it also crosses `/`; `**`
and `**/` mean the same as `*`. So `src/**` matches everything under `src/`, and `**/*.test.ts`
matches a test file at any depth. `[`, `]`, and `?` match themselves, so a route file such as
`app/[id].ts` can be listed exactly as it is named.

## What `/serial-build:scope` writes

```
CLAUDE.md                     the vision, the project's floors, where things live, commits, commands
.claude/rules/serial-build.md the harness's floors, the process, how to write to the owner, coupling
                              and spend rules; no paths filter, so it loads in every session
.claude/rules/                docs, code, and product rules, each scoped to the paths it governs
.claude/serial-build.json     the config above
.claude/settings.json         Claude Code's worktree settings, merged into an existing file:
                              baseRef "head" and the dependency folders to link (see the red lane)
.worktreeinclude              small ignored files (such as .env) copied into each agent worktree
docs/design.md                what the product is, who it is for, what they do today instead,
                              what failure looks like, what it is not
docs/tech/architecture.md     why the code is as it is, by stack; generated files and local gates
docs/glossary.md              the only place a term is defined; five entries for the owner's approval
docs/roadmap.md               the first gate in full, then three to six later gates in a line each,
                              under "Later:" lines
docs/done.md                  shipped gates with their proof; starts empty
docs/open.md                  open questions by slug
docs/decisions/               the scoping decision, dated; under sources/ the interview verbatim and
                              the answers file, which a later /serial-build:scope reuses
claude_outputs/README.md      the inbox; .gitignore gains lines so it, agent worktrees, and the
                              per-user permissions file are never committed
```

In a repository that already has a CLAUDE.md, the file keeps everything it had and gains this
project's section at its end, marked with `<!-- serial-build -->` so it is added only once. The
harness's rules sit in their own file, so they apply either way. `docs/plan.md` does not exist
until `/serial-build:gate` writes it, and shipping deletes it; there is only ever one active plan.

## The red lane

The red lane exists because gates kept being proven green by the same session that built them.
Such a gate covers only the scenario its checks were written for, while an adversarial review,
whose goal was to make things fail, found sixteen problems.

- **Every gate lists what to try.** Each gate has a "Tried to break" section in the roadmap and in
  its plan: the attacks the red lane must at least attempt. Every demo ends with a **"Break it:"
  step** for the owner, modelled on this one: feed it a valid input beside a deliberately broken
  sibling input, and confirm only the broken one is refused, naming what is wrong. The canon check
  fails a gate without either.
- **The attacker works in isolation.** The red-breaker agent runs in its own git worktree, a
  separate checkout of the last commit, which Claude Code places at
  `.claude/worktrees/agent-<id>/` inside the project. By default Claude Code cuts it from the
  remote's default branch, so the scaffold sets `worktree.baseRef` to `"head"` in
  `.claude/settings.json`; otherwise the agent would attack the pushed code, not the gate. A
  worktree has no ignored files, so the same file links the dependency folders the tests need
  (`worktree.symlinkDirectories`, such as `node_modules`) and `.worktreeinclude` copies small ones
  (`.env`). `red-import.sh` copies back only files under
  `red.test_paths`, and voids the run if the agent changed anything else there, deleted a test,
  or committed. `red-guard.sh` checks the project itself and the parts of `.git` every worktree
  shares (config, exclude rules, hooks), including ignored and non-ASCII files, and voids the
  run if anything moved. It does not watch agent worktrees, the per-user permissions file, or
  the linked dependency folders, whose caches the agent's test runs legitimately write through
  the link. The `red-fence` hook is only the early warning. Two gaps remain: a file planted in a
  linked dependency folder, and a file in another ignored folder that is modified and then
  back-dated.
- **Findings are recorded in the active plan**, under `## Red`, one bullet each (it may wrap):
  what breaks, the test file with its git blob hash (a fingerprint of its exact content), and a
  `Reproduce:` command. Each run also records how many attacks it made, lists the ones that
  found nothing, and cites the agent's raw output, which is filed verbatim under the decision
  sources.
- **Open or resolved is computed, never declared.** The record counts only once committed.
  `red-status.sh` treats a finding as resolved only when its test file still has the recorded
  content, its run (the "Red run:" line and every finding under it) is exactly as first
  committed, and its reproduce command passes. Each run is compared by position with the oldest
  commit that held it, so rewriting a run and its commands in a later commit reopens all its
  findings. Deleting the test, weakening it, or editing the command reopens the finding. History
  is read only since the current plan began, so a red slug reused by a later gate does not
  collide. A red record with no attempts, missing attempts, fewer attempts than the plan's list,
  or no raw output does not count.
- **Two ways out, both by script.** A finding the owner judges wrong is demoted with
  `ship-gate.sh --demote`, which commits their words; `/serial-build:red` asks the owner first
  and never demotes on its own judgement. A typed "Demoted" line does not count. The check
  behind this is a commit title, so it stops accidents and shortcuts, not a determined forger:
  anyone can hand-write a commit with the same title. A test that a fix had to change (an import
  moved) is re-pinned with `red-repin.sh` after a `/serial-build:red` re-run confirms it: the
  script refuses unless the changed test still fails on the commit from before the fix. The one
  gap here: a changed test that fails before the fix for an unrelated reason (it imports
  something only the fix created). The breaker's confirmation is what covers that.
- **When the gate ships**, each finding's reproduce command joins its proof in done, so the bug it
  caught is re-checked at every later handoff.

The failing tests are committed on purpose, which means continuous integration and any
pre-commit test hook will fail until the fix lands. Build each gate on its own branch if that
matters; on the default branch, `/serial-build:red` asks before committing them. While a red test
fails, the stop hook points it out once per change to the code, not at every turn.

## Coupling and footprint

- **In unrelated projects:** the hooks exit after checking one file does not exist. The skill and
  agent descriptions add about 900 tokens to every session's context (measured with
  `claude plugin details`), which is the cost of being installed user-wide. Install with
  `--scope project` to avoid it elsewhere.
- **Into your project:** only what `/serial-build:scope` shows you and you approve, plus the
  hooks' behaviour, which the config states. Nothing reads another system's data. The plugin
  makes no network calls and no model calls of its own; the two agents run only when a skill
  launches them. `/serial-build:red` has Claude Code create a git worktree under
  `.claude/worktrees/` and removes it afterwards. The scripts that record a demotion or re-pin
  make their own git commits, because those commits are what the red-status check trusts.
- **Machine requirements:** `sh`, `awk`, `cksum`, `find`, `grep`, and `sed`, which ship with
  macOS and Linux, plus `git` for the stop checks and the red lane.

## Turn it off or remove it

- One project: set `"enabled": false` in its `.claude/serial-build.json`, or delete the file. The
  docs it wrote are ordinary Markdown and stay.
- Everywhere, keeping it installed: `/plugin disable serial-build@serial-build-harness`.
- Remove it: `/plugin uninstall serial-build@serial-build-harness`, then
  `/plugin marketplace remove serial-build-harness`.

## Developing the plugin

```
sh tests/run.sh          # every hook and script, driven the way Claude Code drives them
sh tests/run.sh dash     # the same under dash, to prove the scripts are POSIX and not bash
claude plugin validate --strict .
claude plugin validate --strict plugins/serial-build
```

`tests/` sits outside `plugins/serial-build/`, so none of it is installed with the plugin.
