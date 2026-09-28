# The answers file

`render.sh --answers FILE` fills every `{{key}}` in the templates from one flat JSON object of
strings. Multi-line values use `\n`. A key the templates use and the file lacks fails the render
before anything is written, naming the key; an empty string is a valid answer.

Write each value in the product owner's plain language, consequence first, with every term defined
where it is used. The rendered docs must pass `check-canon.sh`: no file paths and no dates in the
design, roadmap, open-questions, or glossary text; a `See \`slug\`` reference only to a slug that
exists (`project-scope` always does).

| Key | Goes into | What to write |
|---|---|---|
| `project_name` | every doc title | The product's name as the owner says it |
| `project_slug` | nothing yet; kept for later skills | Lowercase, hyphenated |
| `date` | the decision record and its source, by file name | Today, `YYYY-MM-DD` |
| `owner_name` | everywhere the owner is addressed | The name the owner gave |
| `owner_writing` | `.claude/rules/serial-build.md`, "Writing to" | Bullets: how the owner asked to be written to, in their words. The fixed rules follow it |
| `what_it_is` | CLAUDE.md intro, design | Two to four sentences: what it is and the problem it removes |
| `who_uses_it` | design | Who, in what situation, and what they do with it |
| `today_instead` | design, "What they do today instead" | From the open round: what users do now without the product, and what that costs them |
| `failure_in_a_year` | design, "What failure looks like" | From the open round: what the owner said failure would look like a year from now, in their words |
| `goals` | design | Bullets, each a result a user would notice |
| `not_this` | design | Bullets: what it deliberately is not, and why that matters |
| `stack` | design, "How it is built" | Bullets: language, framework, storage, hosting, each with the one-line reason |
| `deployables` | design | Bullets: each thing that ships and runs on its own |
| `floors` | CLAUDE.md, Floors (the harness's own floors are in `.claude/rules/serial-build.md`) | Bullets (`- ` lines, wrapped at 100 columns with two-space continuation): the project's own hard constraints. Each says what it forbids and why; "stop and ask" where crossing it needs the owner |
| `roots_table` | CLAUDE.md, "Where things live" | Markdown table rows, one per root: `` | `src/` | What it holds. What it never holds | `` |
| `test_convention` | CLAUDE.md floors, product rule | Where tests sit in this ecosystem, e.g. "pytest `tests/` beside each package" |
| `generated_files` | architecture, toolchain | Sentences naming each generated file, its source, its generator, and whether it is committed (and why). "None yet." is fine |
| `toolchain` | architecture, toolchain | Paragraphs, each opening with a bold one-sentence decision: runtimes and versions pinned, build machine, how the local gates run |
| `architecture_sections` | architecture | One `## <stack>` section per root or stack, each a few bold-lead paragraphs saying why it is built that way |
| `commands` | CLAUDE.md, "Commands" code block | One line per command a session runs: tests, lint, build, generators, each with a short trailing comment |
| `commit_policy` | CLAUDE.md, "Commits" | One or two sentences, e.g. "Commit finished, proven work without asking; never move a gate to done before the owner runs its demo." |
| `code_paths` | code rule frontmatter | YAML list lines, two-space indent: `  - "src/**"` per line |
| `product_paths` | product rule frontmatter | YAML list lines for the paths that ship |
| `inbox` | CLAUDE.md, the inbox README, .gitignore | The inbox folder name; `claude_outputs` unless the owner chose another. One folder, no slashes |
| `first_stage` | roadmap stage heading | A slug for the first stage of work |
| `first_stage_goal` | roadmap | One sentence: what is true when the stage is over |
| `first_gate_slug` | roadmap gate heading | A slug naming the first slice |
| `first_gate_builds` | roadmap | What the gate produces, concretely |
| `first_gate_demo` | roadmap | The scenario the owner runs and what they should see, then a sentence starting `Break it:` with one thing the owner does to try to break it. Model: "Break it: feed it a valid input beside a deliberately broken sibling input and confirm only the broken one is refused, naming what is wrong." |
| `first_gate_depends` | roadmap | `none.` for the first gate |
| `first_gate_decided` | roadmap | The constraints it honours, naming the scoping record: "... (see `project-scope`)." |
| `first_gate_decide_by_proof` | roadmap | Options to settle by measurement, or `none.` |
| `first_gate_open` | roadmap | Open-question slugs it depends on, each with what it is, or `none.` |
| `first_gate_qa` | roadmap | Mechanical checks that become the proof commands in done |
| `first_gate_tried_to_break` | roadmap | The attacks the red lane must at least try: malformed and boundary inputs, a broken neighbour beside a valid one, repeated or out-of-order steps, limits, missing dependencies |
| `first_gate_acceptance` | roadmap | What the owner does on the running product and the sentence they can then say |
| `later_gates` | roadmap, after the first gate | Three to six later gates, one line each (`- slug: what the owner will be able to do`), in order, under a line starting "Later:" and further `## Stage: <slug>` headings each with a `Goal:` line. Only the first gate is written out in full; intake writes out each later one before it is planned |
| `worktree_symlinks` | `.claude/settings.json`, `worktree.symlinkDirectories` | A JSON list of the ignored dependency folders the tests need, linked into each agent worktree rather than copied: `["node_modules"]`, `[".venv"]`, or `[]` |
| `worktree_include` | `.worktreeinclude` | Gitignore-syntax lines naming the ignored files tests need that are small enough to copy (`.env`, a generated config); empty for none |
| `open_questions` | open questions | Zero or more `## slug` sections, each: the question, why it matters, a recommendation if there is one. Empty string for none |
| `scope_decided` | the scoping decision record | Bold-lead paragraphs: what it is, the first slice, the stack, where things live |
| `scope_rejected` | the scoping decision record | Bullets: options offered in the interview and not chosen, each with why |
| `scope_reopens` | the scoping decision record | What would make this scope wrong |
| `interview_transcript` | the verbatim source | Every question asked, the options offered, and the owner's answer word for word, in order |
