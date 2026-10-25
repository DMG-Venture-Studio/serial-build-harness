#!/bin/sh
# Exercises every serial-build hook and script the way Claude Code calls them:
# JSON on stdin, CLAUDE_PROJECT_DIR set, exit code and stderr as the verdict.
# No model calls. Lives outside plugins/ so none of it ships in the plugin.
# Each hole an adversarial review measured has a test here that keeps it closed.
#
# Usage: sh tests/run.sh [shell to run the scripts with, default sh]
#   e.g. sh tests/run.sh dash    to prove the scripts are POSIX, not bash
set -u
SHELL_UNDER_TEST=${1:-sh}
REPO=$(cd "$(dirname "$0")/.." && pwd)
P="$REPO/plugins/serial-build"
H="$P/hooks/scripts"
S="$P/scripts"
FIX="$REPO/tests/fixtures"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sb-tests.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT
# The snapshot preflight refuses files written in the last two minutes, which is
# every file here; it is switched back on where it is tested.
export SB_RED_QUIET_MINUTES=0
export GIT_AUTHOR_NAME=Ada GIT_AUTHOR_EMAIL=ada@example.com GIT_COMMITTER_NAME=Ada GIT_COMMITTER_EMAIL=ada@example.com
pass=0 fail=0

ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# hook PROJECT SCRIPT JSON: runs a hook; sets code, out, err.
hook() {
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$1" "$SHELL_UNDER_TEST" "$H/$2" > "$WORK/out" 2> "$WORK/err"
  code=$?
  out=$(cat "$WORK/out"); err=$(cat "$WORK/err")
}
# script DIR NAME ARGS...: runs a plugin script from DIR; sets code, out (stdout+stderr).
script() {
  _d=$1 _s=$2; shift 2
  (cd "$_d" && "$SHELL_UNDER_TEST" "$S/$_s" "$@") > "$WORK/out" 2>&1
  code=$?
  out=$(cat "$WORK/out"); err=
}
# expect DESCRIPTION CODE [substring expected in stdout+stderr]
expect() {
  if [ "$code" -ne "$2" ]; then no "$1" "expected exit $2, got $code; output: $out $err"; return; fi
  if [ -n "${3:-}" ]; then
    case "$out$err" in *"$3"*) ;; *) no "$1" "output lacks \"$3\": $out $err"; return ;; esac
  fi
  ok "$1"
}
silent() {
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then ok "$1"; else no "$1" "exit $code; stdout: $out; stderr: $err"; fi
}
check() { if eval "$2"; then ok "$1"; else no "$1" "${3:-}"; fi; }
write_input() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$1"; }
red_input() { printf '{"session_id":"s1","agent_id":"a1","agent_type":"serial-build:red-breaker","tool_name":"%s","tool_input":{%s}}' "$1" "$2"; }
red_bash() { red_input Bash "\"command\":\"$1\""; }
commit() { (cd "$1" && git add -A && git commit -qm "$2"); }
jget() { LC_ALL=C awk -f "$S/json.awk" < "$1" | LC_ALL=C awk -v k="$2" -f "$S/json-decode.awk" -f "$S/json-get.awk"; }

echo "== running with: $SHELL_UNDER_TEST"

# ---------------------------------------------------------------- no config
echo "-- a project without .claude/serial-build.json: every hook is silent"
bare="$WORK/bare"
mkdir -p "$bare/claude_outputs" "$bare/docs"
echo item > "$bare/claude_outputs/left.txt"
printf '# some-gate\n' > "$bare/docs/plan.md"
(cd "$bare" && git init -q && echo x > f.txt)
hook "$bare" session-start.sh '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}'; silent "session-start"
hook "$bare" guard-generated.sh "$(write_input "$bare/src/gen.py")"; silent "guard-generated"
hook "$bare" guard-generated.sh "$(write_input "$bare/docs/done.md")"; silent "the done.md guard is off without config"
hook "$bare" red-fence.sh "$(write_input "$bare/src/app.py")"; silent "red-fence (main session)"
hook "$bare" edit-checks.sh "$(write_input "$bare/f.txt")"; silent "edit-checks"
hook "$bare" inbox-touch.sh '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls claude_outputs"}}'; silent "inbox-touch"
hook "$bare" inbox-stop.sh '{"session_id":"s1","stop_hook_active":false}'; silent "inbox-stop"
hook "$bare" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'; silent "stop-checks"
hook "$bare" guard-generated.sh 'not json at all'; silent "garbage stdin"
check "no state written for an unconfigured project" '[ -z "$(ls -A "$TMPDIR")" ]' "$(ls -A "$TMPDIR")"
hook "$bare" red-fence.sh "$(red_input Write "\"file_path\":\"$bare/src/app.py\"")"
expect "red-fence refuses the red-breaker agent everywhere without test paths" 2 "no .claude/serial-build.json"

# ---------------------------------------------------------------- scaffold
echo "-- /scope's renderer on a fresh greenfield repository"
proj="$WORK/tally"
mkdir -p "$proj/.claude" && (cd "$proj" && git init -q && cp "$REPO/LICENSE" . && echo '{}' > .claude/settings.json)
script "$proj" detect-state.sh
expect "detect-state: greenfield, even with Claude Code's own .claude/settings.json (review item 12)" 0 "state: greenfield"
rm "$proj/.claude/settings.json"
render() { _a=$1; _d=$2; shift 2; (cd "$_d" && "$SHELL_UNDER_TEST" "$P/skills/scope/scripts/render.sh" --answers "$_a" --config "$FIX/serial-build.json" "$@") > "$WORK/out" 2>&1; code=$?; out=$(cat "$WORK/out"); err=; }
sed 's/"commit_policy"/"commit_policy_gone"/' "$FIX/answers.json" > "$WORK/missing.json"
render "$WORK/missing.json" "$proj"
expect "a missing answer fails, naming the key" 3 "commit_policy"
check "a failed render writes nothing" '[ ! -e "$proj/CLAUDE.md" ]'
render "$FIX/answers.json" "$proj" --dry-run
expect "dry run prints the tree" 0 "roadmap.md"
check "dry run writes nothing" '[ ! -e "$proj/CLAUDE.md" ]'
render "$FIX/answers.json" "$proj"
expect "render writes the scaffold" 0 "wrote or merged 19 files"
missing_files=
for f in CLAUDE.md .claude/serial-build.json .claude/settings.json .worktreeinclude .claude/rules/serial-build.md .claude/rules/docs.md .claude/rules/code.md .claude/rules/product.md \
  docs/design.md docs/tech/architecture.md docs/glossary.md docs/roadmap.md docs/done.md docs/open.md \
  docs/decisions/2026-10-01-project-scope.md docs/decisions/sources/scoping-interview-2026-10-01.md \
  docs/decisions/sources/scoping-answers-2026-10-01.json claude_outputs/README.md .gitignore LICENSE; do
  [ -f "$proj/$f" ] || missing_files="$missing_files $f"
done
check "scaffold has every expected file" '[ -z "$missing_files" ]' "$missing_files"
check "worktrees start from HEAD and link the test dependencies (review item 3)" '[ "$(jget "$proj/.claude/settings.json" worktree.baseRef)" = head ] && [ "$(jget "$proj/.claude/settings.json" worktree.symlinkDirectories.0)" = .venv ] && grep -qx ".env" "$proj/.worktreeinclude"'
refs=$(cat "$proj/CLAUDE.md" "$proj/.claude/rules/serial-build.md" | grep -o '`[^` ]*`' | tr -d '`' | grep -E '^(\.claude|docs|claude_outputs)/' | sed 's/#.*//' | sort -u)
missing_refs=$(for r in $refs; do [ -e "$proj/$r" ] || [ "$r" = docs/plan.md ] || printf '%s ' "$r"; done)
check "every path CLAUDE.md and the harness rules name exists (docs/plan.md is created by /gate)" '[ -z "$missing_refs" ]' "$missing_refs"
leftover=$(grep -rn '{{' "$proj" --exclude-dir=.git)
check "no placeholder left unfilled" '[ -z "$leftover" ]' "$leftover"
check "the harness rules load always (no paths filter)" '! grep -q "^paths:" "$proj/.claude/rules/serial-build.md"'
check "the harness rules carry the decoupling rule (review item 17)" 'grep -q "Stay realistically decoupled" "$proj/.claude/rules/serial-build.md"'
check "design records what users do today and what failure looks like (review item 10)" 'grep -q "## What they do today instead" "$proj/docs/design.md" && grep -q "stopped trusting" "$proj/docs/design.md"'
later=$(grep -c '^- [a-z0-9-]*: ' "$proj/docs/roadmap.md")
check "the roadmap names later gates under stage headings (review item 10)" '[ "$later" -ge 3 ] && [ "$(grep -c "^## Stage:" "$proj/docs/roadmap.md")" -ge 2 ]' "later=$later"
script "$proj" check-config.sh
expect "check-config accepts the written config" 0 "OK"
script "$proj" check-canon.sh
expect "check-canon passes on the scaffold" 0 "PASS  every roadmap gate has"
terms=$(grep -rniwE 'phase|scene|scenes|audio|spanish|entender|fili|swift' "$proj" "$P" "$REPO/README.md" --exclude-dir=.git | grep -v 'LICENSE')
check "no source-project terms in the scaffold, the plugin, or the README" '[ -z "$terms" ]' "$terms"
render "$FIX/answers.json" "$proj" --dry-run
case "$out" in *"(new)"*|*"(exists, kept)"*|*append*) no "a second render marks every file same" "$out" ;; *) ok "a second render marks every file same" ;; esac
echo "# hand-edited" >> "$proj/docs/design.md"
render "$FIX/answers.json" "$proj"
expect "an edited file is kept" 0 "kept 1 existing files"
check "the owner's edit survives" 'grep -q "# hand-edited" "$proj/docs/design.md"'
render "$FIX/answers.json" "$proj" --overwrite docs/design.md
check "--overwrite replaces the named file" '! grep -q "# hand-edited" "$proj/docs/design.md"'
render "$FIX/answers.json" "$proj" --overwrite docs/nope.md
expect "--overwrite refuses a path the scaffold does not write" 1 "not a file this scaffold writes"
rm "$proj/docs/open.md"
(cd "$proj" && "$SHELL_UNDER_TEST" "$P/skills/scope/scripts/render.sh" --answers docs/decisions/sources/scoping-answers-2026-10-01.json --config .claude/serial-build.json) > "$WORK/out" 2>&1; code=$?; out=$(cat "$WORK/out")
expect "re-running /scope from the saved answers fills only the missing file (review item 20)" 0 "wrote or merged 1 files"

echo "-- /scope on an existing repository"
old="$WORK/existing"
mkdir -p "$old/src" "$old/.claude" && printf 'node_modules/\n' > "$old/.gitignore" && echo 'print(1)' > "$old/src/main.py" && echo '# Mine' > "$old/CLAUDE.md"
printf '{\n  "enabledPlugins": {\n    "serial-build@serial-build-harness": true\n  }\n}\n' > "$old/.claude/settings.json"
script "$old" detect-state.sh
expect "detect-state: existing" 0 "state: existing"
render "$FIX/answers.json" "$old" --dry-run
expect "the dry run says an existing CLAUDE.md gains a marked section" 0 "(append marked section)"
check "the dry run says an existing .claude/settings.json gains the worktree block" 'printf "%s" "$out" | grep -q "settings.json.*(merge worktree settings)"'
render "$FIX/answers.json" "$old"
check "an existing CLAUDE.md keeps its content and gains the vision once, marked (review item 8)" '[ "$(head -n 1 "$old/CLAUDE.md")" = "# Mine" ] && [ "$(grep -c "<!-- serial-build -->" "$old/CLAUDE.md")" = 1 ] && grep -q "Tally is a command-line tool" "$old/CLAUDE.md"'
render "$FIX/answers.json" "$old"
check "a second render does not append it again" '[ "$(grep -c "<!-- serial-build -->" "$old/CLAUDE.md")" = 1 ]'
check "an existing .claude/settings.json keeps its keys and gains the worktree block (review item 3)" '[ "$(jget "$old/.claude/settings.json" enabledPlugins.serial-build@serial-build-harness)" = true ] && [ "$(jget "$old/.claude/settings.json" worktree.baseRef)" = head ]' "$(cat "$old/.claude/settings.json")"
render "$FIX/answers.json" "$old" --dry-run
check "a second render leaves the merged settings alone" 'printf "%s" "$out" | grep -q "settings.json.*(same)"'
check ".gitignore keeps its lines and gains the inbox's" 'grep -qx "node_modules/" "$old/.gitignore" && grep -qx "claude_outputs/\*" "$old/.gitignore"'

# ---------------------------------------------------------------- hooks with config
echo "-- hooks in the scaffolded project"
mkdir -p "$proj/src/tally" "$proj/tests" "$proj/web/app"
printf 'exit 0\n' > "$proj/tests/check.sh"
echo 'x = 1' > "$proj/src/tally/core.py"
echo 'z' > "$proj/src/café.py"
printf '.env\nnode_modules/\n.venv/\n' >> "$proj/.gitignore"
mkdir -p "$proj/node_modules/pkg" && echo 'module.exports = 1' > "$proj/node_modules/pkg/index.js"
mkdir -p "$proj/.venv/lib" && echo 'x' > "$proj/.venv/lib/site.py"
commit "$proj" scope

hook "$proj" guard-generated.sh "$(write_input "$proj/src/tally/_version.py")"
expect "guard refuses an edit to a generated file, naming the regenerate command" 2 "setuptools_scm"
hook "$proj" guard-generated.sh "$(write_input "$proj/src/tally/core.py")"; silent "guard allows a hand-written file"
hook "$proj" guard-generated.sh '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$proj"'/src/tally/_version.py"}}'
expect "guard covers notebook edits" 2 "generated file"
hook "$proj" guard-generated.sh "$(write_input "$proj/web/app/[id].ts")"
expect "a generated path with brackets is guarded as written (review item 11)" 2 "web/app/[id].ts"
hook "$proj" guard-generated.sh "$(write_input "$proj/web/app/i.ts")"; silent "brackets are not a character class: web/app/i.ts is not guarded"
hook "$proj" guard-generated.sh "$(write_input "$proj/docs/done.md")"
expect "a hand edit to docs/done.md is refused, naming ship-gate (review item 2)" 2 "ship-gate.sh"

echo 'FORBIDDEN' >> "$proj/src/tally/core.py"
hook "$proj" edit-checks.sh "$(write_input "$proj/src/tally/core.py")"
expect "edit check fails and feeds the output back" 2 "no forbidden marker failed"
hook "$proj" edit-checks.sh "$(write_input "$proj/tests/check.sh")"; silent "edit check skips paths outside its rule"
sed '/FORBIDDEN/d' "$proj/src/tally/core.py" > "$WORK/c" && cp "$WORK/c" "$proj/src/tally/core.py"
hook "$proj" edit-checks.sh "$(write_input "$proj/src/tally/core.py")"; silent "edit check passes silently"

hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'; silent "stop check does nothing on a clean tree"
echo 'y = 2' >> "$proj/src/tally/core.py"
printf 'echo "1 test failed: core"; exit 1\n' > "$proj/tests/check.sh"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'
expect "stop check fails on uncommitted changes and keeps the session working" 2 "1 test failed"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":true}'; silent "stop check never loops (stop_hook_active)"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'
expect "the same failing tree does not re-run or block again (review item 3)" 0 "still fails on these unchanged files"
echo 'y = 3' >> "$proj/src/tally/core.py"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'
expect "a changed tree that still fails blocks again" 2 "1 test failed"
hook "$proj" session-start.sh '{"session_id":"s9","source":"startup"}'
expect "the next session is told the tests were failing (review item 14)" 0 "a stop check was failing"
printf 'exit 0\n' > "$proj/tests/check.sh"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'
expect "stop check passes" 0 "tests passed"
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'; silent "an unchanged passing tree does not re-run"
hook "$proj" session-start.sh '{"session_id":"s9","source":"startup"}'
case "$out" in *"was failing"*) no "the warning clears once the tests pass" "$out" ;; *) ok "the warning clears once the tests pass" ;; esac
mkdir -p "$proj/junk" && (cd "$proj/junk" && i=0; while [ $i -lt 2000 ]; do : > "f$i.txt"; i=$((i + 1)); done)
t0=$(date +%s)
hook "$proj" stop-checks.sh '{"session_id":"s1","stop_hook_active":false}'
t1=$(date +%s)
check "stop check with 2000 untracked files outside its paths takes under 5 s (review item 7; it took $((t1 - t0)) s)" '[ $((t1 - t0)) -lt 5 ]'
rm -rf "$proj/junk"

hook "$proj" session-start.sh '{"session_id":"s2","source":"startup"}'
expect "session start names the next gate" 0 "next roadmap gate is match-one-month"
echo 'dropped' > "$proj/claude_outputs/brief.md"
hook "$proj" session-start.sh '{"session_id":"s2","source":"startup"}'
expect "session start lists the inbox" 0 "brief.md"
hook "$proj" inbox-stop.sh '{"session_id":"s2","stop_hook_active":false}'; silent "inbox stop ignores a session that never touched the inbox"
hook "$proj" inbox-touch.sh '{"session_id":"s2","tool_name":"Read","tool_input":{"file_path":"'"$proj"'/claude_outputs/brief.md"}}'; silent "inbox touch is silent"
hook "$proj" inbox-stop.sh '{"session_id":"s2","stop_hook_active":false}'
expect "inbox stop blocks a session that touched it and left items" 2 "brief.md"
hook "$proj" inbox-stop.sh '{"session_id":"s2","stop_hook_active":false}'; silent "inbox stop nags once per listing"
rm "$proj/claude_outputs/brief.md"
hook "$proj" inbox-stop.sh '{"session_id":"s2","stop_hook_active":false}'; silent "inbox stop passes once emptied"
commit "$proj" build

# ---------------------------------------------------------------- the fence
echo "-- the red lane's fence (advisory; the worktree and red-guard are the guarantee)"
# Claude Code puts the breaker's worktree inside the project; hooks see
# CLAUDE_PROJECT_DIR as the main project and run with the worktree as cwd.
wt="$proj/.claude/worktrees/agent-sim"
hook_in() { # hook_in CWD PROJECT SCRIPT JSON
  (cd "$1" && printf '%s' "$4" | CLAUDE_PROJECT_DIR="$2" "$SHELL_UNDER_TEST" "$H/$3") > "$WORK/out" 2> "$WORK/err"
  code=$?; out=$(cat "$WORK/out"); err=$(cat "$WORK/err")
}
hook "$proj" red-fence.sh "$(red_input Write "\"file_path\":\"$proj/src/tally/core.py\"")"
expect "red-breaker cannot write product code" 2 "writes tests only"
hook "$proj" red-fence.sh "$(red_input Edit "\"file_path\":\"$proj/tests/test_red.py\"")"; silent "red-breaker may write a test"
for c in 'cd src && git commit -am sneaky' 'git stash' '\"git\" commit -m x' 'git co -b x' 'git rm src/tally/core.py' 'git branch -f main HEAD~1' 'git branch -D main' 'git -c user.name=x commit -m y' 'sh -c \"git push\"' 'X=1 env git push' 'time git reset --hard' "g\\\\\\\\it commit" 'git reflog expire --all' 'git worktree remove x' 'git stash drop' 'sudo -u me git commit -m x' 'sudo -i git push' 'nice -n 5 git commit -m x' 'timeout 5 git commit -m x' 'timeout -s KILL 5 git push' 'bash -lc \"git push\"' 'eval \"git commit -m x\"' 'find . -exec git add {} \\;'; do
  hook "$proj" red-fence.sh "$(red_bash "$c")"
  expect "red-breaker is refused: $c" 2 "only read-only git commands"
done
for c in 'timeout 60 sh tests/check.sh' 'find . -name x -exec grep -l git {} \\;' 'nice -n 5 git status' 'bash -lc \"git log\"' 'uv run pytest -q tests/ && git status' 'git -C . diff HEAD' 'git log --oneline -3' 'git hash-object tests/x.py' 'git stash list' 'git branch --show-current' 'git branch' 'git worktree list' 'git reflog' 'git remote -v' 'git config --get user.name' 'grep -rn \"git commit\" docs/' 'npm test -- --grep \"git merge\"'; do
  hook "$proj" red-fence.sh "$(red_bash "$c")"; silent "red-breaker may run: $c (review item 11)"
done
hook "$proj" red-fence.sh "$(write_input "$proj/src/tally/core.py")"; silent "the builder is not fenced"
printf '{"agent_type":"general-purpose","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$proj/src/x.py" > "$WORK/in"
hook "$proj" red-fence.sh "$(cat "$WORK/in")"; silent "other subagents are not fenced"
(cd "$proj" && git worktree add -q --detach "$wt" HEAD)
hook_in "$wt" "$proj" red-fence.sh "$(red_input Write "\"file_path\":\"$wt/tests/test_probe.py\"")"; silent "red-breaker may write a test in its worktree at .claude/worktrees/agent-sim (review item 1)"
hook_in "$wt" "$proj" red-fence.sh "$(red_input Write "\"file_path\":\"$wt/src/tally/core.py\"")"
expect "red-breaker cannot write product code in that worktree" 2 "src/tally/core.py is not under the test paths"
hook_in "$wt" "$proj" edit-checks.sh "$(write_input "$wt/src/tally/core.py")"; silent "edit checks ignore files in agent worktrees"
(cd "$proj" && git worktree remove --force "$wt")

# ---------------------------------------------------------------- red-guard
echo "-- red-guard: the project and shared .git are untouched by the breaker"
echo 'dirty = 1' >> "$proj/src/tally/core.py"
script "$proj" red-guard.sh snapshot
expect "snapshot refuses uncommitted work, which a worktree would not see" 1 "commit the gate's work first"
git -C "$proj" checkout -q -- src/tally/core.py
guard_case() { # guard_case DESCRIPTION EXPECTED-SUBSTRING COMMAND-THAT-TAMPERS UNDO
  script "$proj" red-guard.sh snapshot
  eval "$3"
  script "$proj" red-guard.sh verify
  if [ "$2" = OK ]; then expect "$1" 0 "nothing but tests changed"; else expect "$1" 1 "$2"; fi
  eval "$4"
}
guard_case "verify passes when only a test changed, listing it" OK 'echo "assert 0" > "$proj/tests/test_red.py"' 'rm -f "$proj/tests/test_red.py"'
guard_case "verify passes while the agent worktree still exists inside the project (review item 2)" OK '(cd "$proj" && git worktree add -q --detach "$wt" HEAD) && echo "exit 1" > "$wt/tests/red_w.sh" && echo planted >> "$wt/src/tally/core.py"' '(cd "$proj" && git worktree remove --force "$wt")'
guard_case "verify passes when the owner's permissions file changes (review item 2)" OK 'echo "{\"permissions\":{\"allow\":[\"Bash(ls)\"]}}" > "$proj/.claude/settings.local.json"' 'rm -f "$proj/.claude/settings.local.json"'
guard_case "verify ignores caches written through a linked dependency folder (review item 3)" OK 'sleep 1; mkdir -p "$proj/.venv/lib/.cache" && echo c > "$proj/.venv/lib/.cache/x"' ':'
guard_case "a planted gitignored .env voids the run" ".env changed" 'echo SECRET=1 > "$proj/.env"' 'rm -f "$proj/.env"'
guard_case "an edit to .git/info/exclude voids the run" ".git/info/exclude changed" 'echo "src/sitecustomize.py" >> "$proj/.git/info/exclude"; echo "import os" > "$proj/src/sitecustomize.py"' 'sed "/sitecustomize/d" "$proj/.git/info/exclude" > "$WORK/x" && cp "$WORK/x" "$proj/.git/info/exclude"; rm -f "$proj/src/sitecustomize.py"'
guard_case "a planted .git/hooks/post-commit voids the run" ".git/hooks/post-commit changed" 'printf "#!/bin/sh\necho planted >> src/tally/core.py\n" > "$proj/.git/hooks/post-commit"' 'rm -f "$proj/.git/hooks/post-commit"'
guard_case "a change to a non-ASCII path voids the run, named plainly" "src/café.py changed" 'echo planted >> "$proj/src/café.py"' 'git -C "$proj" checkout -q -- .'
guard_case "a change inside an ignored folder that is not linked voids the run" "node_modules/ changed" 'sleep 1; echo planted >> "$proj/node_modules/pkg/index.js"' ':'
guard_case "product code changed voids the run" "src/tally/core.py changed, and it is not a test" 'echo sneaky >> "$proj/src/tally/core.py"' 'git -C "$proj" checkout -q -- .'
guard_case "a commit voids the run" "commit moved" 'echo "t" > "$proj/tests/t.txt"; commit "$proj" sneaky' ':'

# ---------------------------------------------------------------- red-import
echo "-- red-import: only tests come home from the breaker's worktree"
import_case() { # import_case DESCRIPTION CODE EXPECTED IN-WORKTREE-COMMANDS
  script "$proj" red-guard.sh snapshot
  (cd "$proj" && git worktree add -q --detach "$wt" HEAD)
  (cd "$wt" && eval "$4")
  script "$proj" red-import.sh "$wt" --remove
  expect "$1" "$2" "$3"
  [ -d "$wt" ] && (cd "$proj" && git worktree remove --force "$wt")
}
import_case "a new test comes home from .claude/worktrees/agent-sim, ignored leftovers stay, the worktree is removed (review item 1)" 0 "tests/red_new.sh" 'echo "exit 1" > tests/red_new.sh; echo "left by a test run" > .env'
check "the imported test is in the project" '[ -f "$proj/tests/red_new.sh" ] && [ ! -d "$wt" ]'
script "$proj" red-guard.sh snapshot
(cd "$proj" && git worktree add -q -b worktree-agent-sim "$wt" HEAD && echo "exit 1" > "$wt/tests/red_b.sh")
script "$proj" red-import.sh "$wt" --remove
expect "red-import deletes the branch Claude Code made for the agent (live run)" 0 "deleted its branch worktree-agent-sim"
check "no agent branch is left" '! git -C "$proj" branch --list "worktree-agent-*" | grep -q .'
rm -f "$proj/tests/red_b.sh"
script "$proj" red-guard.sh verify
expect "verify after import sees only the imported test" 0 "tests/red_new.sh"
rm -f "$proj/tests/red_new.sh"
import_case "a product-code change in the worktree voids the run, copying nothing" 1 "src/tally/core.py changed, and it is not a test" 'echo "exit 1" > tests/red_two.sh; echo planted >> src/tally/core.py'
check "nothing was copied from a void run" '[ ! -f "$proj/tests/red_two.sh" ]'
import_case "a deleted test voids the run" 1 "a test, was deleted" 'rm tests/check.sh'
import_case "a commit in the worktree voids the run" 1 "committed or started elsewhere" 'echo x > tests/x.sh; git add -A; git commit -qm x'

# ---------------------------------------------------------------- red lock and preflight (issue 1)
echo "-- the red lock and the snapshot preflight: other writers are stopped, not just caught"
script "$proj" red-guard.sh abort
export SB_RED_QUIET_MINUTES=2
echo "log line" > "$proj/.env"
script "$proj" red-guard.sh snapshot
expect "the snapshot refuses while an ignored file is still being written, naming it" 1 "something is still writing into the project"
check "and names the file" 'printf "%s" "$out" | grep -qx ".env"' "$out"
find "$proj/.env" "$proj/node_modules" -exec touch -t 200001010000 {} +
script "$proj" red-guard.sh snapshot
expect "the snapshot proceeds once nothing has written for two minutes" 0 "the red lock is held"
export SB_RED_QUIET_MINUTES=0
main_bash() { printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
hook "$proj" red-lock.sh "$(write_input "$proj/src/tally/core.py")"
expect "while the lock is held the builder cannot write into the project" 2 "The red lock is held"
hook "$proj" red-lock.sh "$(write_input "$proj/.claude/worktrees/agent-x/src/a.py")"
expect "nor into an agent worktree" 2 "red lock is held"
hook "$proj" red-lock.sh "$(write_input "$WORK/elsewhere/notes.md")"; silent "a write outside the project passes"
hook "$proj" red-lock.sh "$(red_input Write "\"file_path\":\"$proj/.claude/worktrees/agent-x/tests/t.py\"")"; silent "the red-breaker agent is not locked out"
hook "$proj" red-lock.sh "$(red_bash "uv run pytest tests/t.py")"; silent "the red-breaker agent may run its tests"
for c in 'uv run pytest -q' 'ruff check src' 'echo x > cat' 'ls; touch src/x' 'cat a | tee b' 'find . -name x -delete' 'git checkout -- .' 'sh tests/check.sh' 'make dev' 'git stash' 'ls $(rm -rf src)' 'sh /p/scripts/red-guard.sh verify; rm -rf src' 'rm -rf src /x/scripts/red-guard.sh' 'touch evil /x/scripts/red-file.sh' 'sort -o f a' 'uniq a out' 'date -s 12:00' 'git diff --output=x' 'git log --output=x' 'git -c core.fsmonitor=evil status' "git log > $proj/out.txt" 'git log > out.txt' "ls > $proj/.git/hooks/post-commit" "cat a | tee $proj/src/x" 'gh pr merge 3' 'gh api repos/x' "git -C $proj push" 'sort -o f a' 'rg --pre cat x' 'git log > /tmp/../$proj/x'; do
  hook "$proj" red-lock.sh "$(main_bash "$c")"
  expect "the lock refuses for the builder: $c" 2 "is refused while it is held"
done
for c in 'sh /x/scripts/red-file.sh --output /tmp/o.md --cost \"26 min, 1.4M tokens\"' 'git status' 'git log --oneline -3' 'ls -la 2>/dev/null' 'grep -rn x src | head -n 3' 'ps aux' 'kill 4242' 'find . -name *.log -mmin -2' 'git worktree list' 'sh /x/plugins/serial-build/scripts/red-guard.sh verify' 'sh /x/scripts/red-guard.sh abort' 'sh /x/scripts/red-file.sh --output /tmp/o.md --worktree /p/.claude/worktrees/agent-1' 'sh \"/x y/scripts/red-pack.sh\" core' 'FOO=1 pwd' "git log --oneline > $WORK/notes/log.txt" "cat a | tail -n 3 > $WORK/t.txt 2>&1" "git diff | tee $WORK/d.txt | head" 'gh run list' 'gh pr view 3 --comments' 'gh issue list -R o/r' "git -C $proj remote get-url origin" "git -C $proj log -1" 'git branch -a' 'sort -u a | uniq -c' 'date +%s' 'sh /x/scripts/red-brief.sh --out /tmp/rb --lane core'; do
  hook "$proj" red-lock.sh "$(main_bash "$c")"; silent "the lock allows for the builder: $c"
done
hook "$proj" session-start.sh '{"session_id":"s4","source":"startup"}'
expect "session start reports a held lock and how to release it" 0 "the red lock is held"
check "the lock lives in the shared .git, not the temp folder the hook and the shell may not share (review)" 'ls "$proj"/.git/serial-build/red-lock-* >/dev/null 2>&1'
(cd "$proj" && TMPDIR="$WORK/othertmp" && mkdir -p "$TMPDIR" && export TMPDIR && printf '%s' "$(write_input "$proj/src/tally/core.py")" | CLAUDE_PROJECT_DIR="$proj" "$SHELL_UNDER_TEST" "$H/red-lock.sh") > /dev/null 2>&1; code=$?
check "a hook with another TMPDIR still sees the lock" '[ "$code" = 2 ]' "exit $code"
script "$proj" red-guard.sh verify
expect "verify passes" 0 "nothing but tests changed"
hook "$proj" red-lock.sh "$(write_input "$proj/src/tally/core.py")"; silent "verify releases the lock"
script "$proj" red-guard.sh snapshot
script "$proj" red-guard.sh snapshot
expect "a second snapshot is refused while a run holds the lock" 1 "already holds the red lock"
script "$proj" red-guard.sh abort
expect "abort voids the run" 0 "the red lock is released"
hook "$proj" red-lock.sh "$(write_input "$proj/src/tally/core.py")"; silent "abort releases the lock"
script "$proj" red-guard.sh verify
expect "abort drops the snapshot, so the aborted run cannot be verified" 1 "no snapshot"
hook "$bare" red-lock.sh "$(write_input "$bare/src/app.py")"; silent "the lock is silent without config"
rm -f "$proj/.env"

echo "-- red-guard compares .git/config by its settings (issue 1)"
git -C "$proj" config core.hooksPath .githooks
guard_case "a relative core.hooksPath rewritten as the same absolute folder is no change" OK 'git -C "$proj" config core.hooksPath "$proj/.githooks"' 'git -C "$proj" config core.hooksPath .githooks'
guard_case "a core.hooksPath pointed at another folder voids the run" ".git/config changed" 'git -C "$proj" config core.hooksPath /tmp/planted-hooks' 'git -C "$proj" config core.hooksPath .githooks'
guard_case "any other config change voids the run" ".git/config changed" 'git -C "$proj" config alias.st status' 'git -C "$proj" config --unset alias.st'
git -C "$proj" config --unset core.hooksPath

echo "-- salvaging a voided run, and lanes that collide (issues 1, 3)"
script "$proj" red-guard.sh snapshot
(cd "$proj" && git worktree add -q --detach "$wt" HEAD) && echo "exit 1" > "$wt/tests/red_salvage.sh" && echo planted >> "$wt/src/tally/core.py"
script "$proj" red-import.sh "$wt" --quarantine "$proj/q"
expect "the quarantine folder must be outside the project" 1 "must be outside the project"
script "$proj" red-import.sh "$wt" --quarantine "$WORK/quarantine" --remove
expect "a voided run's tests are quarantined, not imported" 0 "quarantined, not imported"
check "only the test is salvaged, into the quarantine, and nothing reaches the project" '[ -f "$WORK/quarantine/agent-sim/tests/red_salvage.sh" ] && [ ! -e "$WORK/quarantine/agent-sim/src/tally/core.py" ] && [ ! -e "$proj/tests/red_salvage.sh" ] && [ ! -d "$wt" ]'
wt2="$proj/.claude/worktrees/agent-two"
script "$proj" red-guard.sh snapshot
(cd "$proj" && git worktree add -q --detach "$wt" HEAD && git worktree add -q --detach "$wt2" HEAD)
echo "exit 1" > "$wt/tests/red_lane_a.sh"; echo "exit 1" > "$wt2/tests/red_lane_b.sh"
script "$proj" red-import.sh "$wt" "$wt2"
expect "two lanes' tests come home in one import" 0 "tests/red_lane_b.sh"
check "both are in the project" '[ -f "$proj/tests/red_lane_a.sh" ] && [ -f "$proj/tests/red_lane_b.sh" ]'
rm -f "$proj/tests/red_lane_a.sh" "$proj/tests/red_lane_b.sh"
echo "exit 1" > "$wt2/tests/red_lane_a.sh"
script "$proj" red-import.sh "$wt" "$wt2" --remove
expect "two lanes writing the same test file void the run, copying nothing" 1 "written by two lanes"
check "nothing was copied from the collision" '[ ! -f "$proj/tests/red_lane_a.sh" ] && [ ! -f "$proj/tests/red_lane_b.sh" ]'
(cd "$proj" && git worktree remove --force "$wt" && git worktree remove --force "$wt2")
script "$proj" red-guard.sh abort

# ---------------------------------------------------------------- red-status
echo "-- red-status: a finding resolves only by fixing the code"
cat > "$proj/tests/red_empty.sh" <<'EOF'
grep -q refuse_empty src/tally/core.py
EOF
blob=$(git -C "$proj" hash-object tests/red_empty.sh)
mkdir -p "$proj/docs/decisions/sources"
echo "# Source: red-breaker output, verbatim" > "$proj/docs/decisions/sources/red-match-one-month-2026-10-02.md"
echo "# Source: red-breaker confirms the re-pinned test" > "$proj/docs/decisions/sources/red-repin-confirm.md"
plan_head() {
  cat <<'EOF'
# match-one-month

Acceptance: Ada runs Tally on last month's files and can say the list is right.

- [x] Parse the statement.
- [ ] Colour the output.

Proof (the commands done will re-run):

    sh tests/check.sh

Tried to break (the red lane attempts at least these):
- an empty statement
- a valid file beside a broken one

Blocking open questions: none
EOF
}
red_section() { # red_section ATTEMPTS FINDINGS SOURCE ATTEMPT-LIST [wrap]
  printf '\n## Red\n\nRed run: 2026-10-02, %s attempts, %s findings. Source: `%s`.\n\n' "$1" "$2" "$3"
  if [ "$2" -gt 0 ]; then
    if [ "${5:-}" = wrap ]; then
      printf -- '- red-empty-statement: an empty statement (e.g. a header-only export) crashes instead of being refused.\n  Test: `tests/red_empty.sh@%s`.\n  Reproduce: `sh tests/red_empty.sh`.\n\n' "$blob"
    else
      printf -- '- red-empty-statement: an empty statement (e.g. a header-only export) crashes instead of being refused. Test: `tests/red_empty.sh@%s`. Reproduce: `sh tests/red_empty.sh`.\n\n' "$blob"
    fi
  fi
  printf '%s' "$4"
}
attempts='Attempts that found nothing:
- a valid file beside a broken one: only the broken one was refused, naming the line
'
status() { script "$proj" red-status.sh; }
status; expect "no plan, no handoff" 1 "no docs/plan.md"
plan_head > "$proj/docs/plan.md"
status; expect "a gate with no red run does not hand off" 1 "no red run recorded"
{ plan_head; red_section 0 0 red-match-one-month-2026-10-02 "$attempts"; } > "$proj/docs/plan.md"
status; expect "\"0 attempts\" is not a red run" 1 "declares no attempts"
{ plan_head; red_section 2 1 red-match-one-month-2026-10-02 ""; } > "$proj/docs/plan.md"
status; expect "a run must list its fruitless attempts" 1 "no \"Attempts that found nothing:\" list"
{ plan_head; red_section 1 0 red-match-one-month-2026-10-02 "$attempts"; } > "$proj/docs/plan.md"
status; expect "a run must cover the plan's Tried to break list" 1 "declares at least the 2 attempts"
{ plan_head; red_section 5 1 red-match-one-month-2026-10-02 "$attempts"; } > "$proj/docs/plan.md"
status; expect "declared attempts must all be listed" 1 "declares 5 attempts but lists only 1"
{ plan_head; red_section 2 1 red-nowhere "$attempts"; } > "$proj/docs/plan.md"
status; expect "the raw output must be filed" 1 "does not exist"
{ plan_head; red_section 2 1 red-match-one-month-2026-10-02 "$attempts" wrap; } > "$proj/docs/plan.md"
status; expect "an uncommitted red record does not count" 1 "counts once committed"
script "$proj" check-canon.sh
expect "the plan with its Red section passes the canon check" 0 "PASS  the active plan"
commit "$proj" "Red: match-one-month, 1 findings"
status; expect "a finding wrapped over three lines is read whole, and is open (review item 12)" 1 "OPEN      red-empty-statement: \`sh tests/red_empty.sh\` still fails"
echo 'refuse_empty = True' >> "$proj/src/tally/core.py"
status; expect "the handoff proceeds once the code is fixed" 0 "1 of 1 red findings resolved"
mv "$proj/tests/red_empty.sh" "$WORK/red_empty.sh"
status; expect "deleting the red test reopens the finding" 1 "is gone"
mv "$WORK/red_empty.sh" "$proj/tests/red_empty.sh"
printf 'exit 0\n' > "$proj/tests/red_empty.sh"
status; expect "weakening the red test reopens the finding" 1 "changed since it was recorded"
git -C "$proj" checkout -q -- tests/red_empty.sh
sed 's/Reproduce: `sh tests\/red_empty.sh`/Reproduce: `true`/' "$proj/docs/plan.md" > "$WORK/p" && cp "$WORK/p" "$proj/docs/plan.md"
(cd "$proj" && git commit -qam "hand edit")
status; expect "a committed edit to the finding's Reproduce command reopens it" 1 "changed after it was first committed"
git -C "$proj" reset -q --hard HEAD~1
sed 's/^\(Red run: .*\)$/\1 /; s/Reproduce: `sh tests\/red_empty.sh`/Reproduce: `true`/' "$proj/docs/plan.md" > "$WORK/p" && cp "$WORK/p" "$proj/docs/plan.md"
(cd "$proj" && git commit -qam "doctor the run line and its commands together")
status; expect "rewriting a run line and its commands in one commit reopens the finding (third review, item 1)" 1 "(run 1) changed after it was first committed"
script "$proj" ship-gate.sh match-one-month --accepted "fine"
expect "and the gate does not ship on the doctored record" 1 "does not ship while the red lane"
git -C "$proj" reset -q --hard HEAD~1
echo 'refuse_empty = True' >> "$proj/src/tally/core.py"
echo 'Demoted red-empty-statement: "not a bug", approved by Ada.' >> "$proj/docs/plan.md"
(cd "$proj" && git commit -qam "typed demotion")
status; expect "a typed Demoted line does not clear a finding (review item 4)" 1 "not recorded by ship-gate.sh --demote"
git -C "$proj" reset -q --hard HEAD~1
script "$proj" ship-gate.sh --demote red-empty-statement --owner-said "Empty statements are valid; my bank sends them."
expect "ship-gate --demote records and commits the owner's demotion (review item 4)" 0 "demoted on the owner's word"
status; expect "a demotion by ship-gate is listed with the owner's words and does not block" 0 "DEMOTED   red-empty-statement"
git -C "$proj" reset -q --hard HEAD~1

echo "-- re-pinning a red test a fix had to change (review item 13)"
printf '# the fix moved the flag\ngrep -q refuse_empty src/tally/core.py\n' > "$proj/tests/red_empty.sh"
echo 'refuse_empty = True' >> "$proj/src/tally/core.py"
status; expect "a test the fix changed is open until re-pinned" 1 "re-pinned with red-repin.sh"
script "$proj" red-repin.sh red-empty-statement
expect "re-pin needs the breaker's confirmation" 1 "usage"
printf 'exit 0\n' > "$WORK/weak.sh"; cp "$proj/tests/red_empty.sh" "$WORK/keep.sh"; cp "$WORK/weak.sh" "$proj/tests/red_empty.sh"
script "$proj" red-repin.sh red-empty-statement --source red-repin-confirm
expect "a test that passes before the fix is not re-pinned" 1 "no longer catches the bug"
cp "$WORK/keep.sh" "$proj/tests/red_empty.sh"
script "$proj" red-repin.sh red-empty-statement --source red-repin-confirm
expect "a test that still fails before the fix is re-pinned and committed" 0 "re-pinned to tests/red_empty.sh@"
status; expect "the re-pinned finding resolves once the code is fixed" 0 "1 of 1 red findings resolved"
check "the re-pin left no temporary worktree" '[ "$(git -C "$proj" worktree list | wc -l | tr -d " ")" = 1 ]' "$(git -C "$proj" worktree list)"
git -C "$proj" reset -q --hard HEAD~1
echo 'Re-pinned red-empty-statement: Test: `tests/red_empty.sh@0000`. typed.' >> "$proj/docs/plan.md"
(cd "$proj" && git commit -qam "typed re-pin")
status; expect "a typed Re-pinned line does not count (review item 13)" 1 "not recorded by red-repin.sh"
git -C "$proj" reset -q --hard HEAD~1

# ---------------------------------------------------------------- ship-gate
echo "-- ship-gate: done is written by code"
ship() { script "$proj" ship-gate.sh "$@"; }
ship match-one-month
expect "ship-gate needs the owner's words" 1 "usage"
ship other-gate --accepted "fine"
expect "ship-gate refuses a gate that is not the active plan" 1 "not other-gate"
ship match-one-month --accepted "It found my two missing transactions."
expect "ship-gate refuses while a red finding is open" 1 "does not ship while the red lane"
check "a refused ship writes nothing" '[ -f "$proj/docs/plan.md" ] && ! grep -q "^## match-one-month" "$proj/docs/done.md"'
echo 'refuse_empty = True' >> "$proj/src/tally/core.py"
printf 'exit 1\n' > "$proj/tests/check.sh"
ship match-one-month --accepted "It found my two missing transactions."
expect "ship-gate refuses when a proof fails now" 1 "a proof fails now"
printf 'exit 0\n' > "$proj/tests/check.sh"
# A gate whose text holds a fenced "# comment" and a prose "Later," line (review item 8).
awk '{ print } /^Builds: The `tally` command/ { print ""; print "```"; print "# an example comment, not a heading"; print "```"; print ""; print "Later, it may read a second account." }' "$proj/docs/roadmap.md" > "$WORK/r" && cp "$WORK/r" "$proj/docs/roadmap.md"
printf '\nSee `nowhere` for more.\n' >> "$proj/docs/design.md"
# A demo brief drafted into the plan before red (issue 8) holds lines that look like the top block's.
awk '/^## Red$/ { print "## Demo brief"; print ""; print "Proof that it runs:"; print ""; print "    false"; print ""; print "Tried to break it yourself:"; print "- one"; print "- two"; print "- three"; print "" } { print }' "$proj/docs/plan.md" > "$WORK/p" && cp "$WORK/p" "$proj/docs/plan.md"
ship match-one-month --accepted "It found my two missing transactions."
expect "ship-gate ships, and exits 0 even when the canon check after it fails (review item 9)" 0 "the gate shipped, but the canon check above fails"
sed '/See `nowhere`/d' "$proj/docs/design.md" > "$WORK/d" && cp "$WORK/d" "$proj/docs/design.md"
check "no text of the shipped gate is left in the roadmap (review item 8)" '! grep -q "an example comment" "$proj/docs/roadmap.md" && ! grep -q "Later, it may read" "$proj/docs/roadmap.md" && grep -q "^- two-accounts:" "$proj/docs/roadmap.md"'
check "the done entry names each finding by its whole description, not cut at \"e.g.\" (live run)" 'grep -q "red-empty-statement (an empty statement (e.g. a header-only export) crashes instead of being refused)" "$proj/docs/done.md"'
check "a demo brief in the plan adds no proof command and no Tried to break bullets (issue 8)" '! grep -q "^    false" "$proj/docs/done.md"'
check "the done entry carries proof, the red test, what was tried, and the owner's words" 'grep -q "^    sh tests/check.sh" "$proj/docs/done.md" && grep -q "^    sh tests/red_empty.sh" "$proj/docs/done.md" && grep -q "^Tried to break: 2 attempts by the red lane" "$proj/docs/done.md" && grep -q "^Accepted: \"It found my two missing transactions.\"" "$proj/docs/done.md"'
check "the plan is deleted and the gate left the roadmap" '[ ! -f "$proj/docs/plan.md" ] && ! grep -q "^### match-one-month" "$proj/docs/roadmap.md"'
check "ship-gate listed the unticked task" 'printf "%s" "$out" | grep -q "Colour the output"'
script "$proj" check-canon.sh
expect "the ledger passes the canon check after shipping" 0 "PASS  every done entry is as ship-gate.sh wrote it"
sed 's/^Accepted: .*/Accepted: "Perfect in every way."/' "$proj/docs/done.md" > "$WORK/d" && cp "$proj/docs/done.md" "$WORK/done.keep" && cp "$WORK/d" "$proj/docs/done.md"
script "$proj" check-canon.sh
expect "a done entry changed by hand is reported (review item 10)" 1 "entry match-one-month changed after ship-gate.sh wrote it"
cp "$WORK/done.keep" "$proj/docs/done.md"
echo "-- ship-gate --retire-proof: a proof leaves done only for a recorded reason (issue 7)"
retire() { ship --retire-proof match-one-month "$1" --decision red-weekly --owner-said "Run it weekly instead."; }
retire "sh tests/red_empty.sh"
expect "retiring a proof needs a decision record" 1 "no decision record"
printf 'Date: 2026-10-24\n\n## Decided\n\n- The empty-statement check runs weekly.\n\n## Rejected\n\n- Every handoff.\n\n## Reopens if\n\n- It regresses.\n' > "$proj/docs/decisions/2026-10-24-red-weekly.md"
retire "sh tests/red_empty.sh"
expect "the record must be committed" 1 "is not committed"
rec_commit() { git -C "$proj" add -- docs/decisions/2026-10-24-red-weekly.md && git -C "$proj" commit -qm "$1" -- docs/decisions/2026-10-24-red-weekly.md; }
rec_commit "Intake: red-weekly"
ship --retire-proof match-one-month "sh tests/red_empty.sh" --decision red-weekly
expect "retiring a proof needs the owner's words" 1 "usage"
retire "sh tests/nope.sh"
expect "only a command in the entry's Proof block can be retired" 1 "has no command"
retire "sh tests/red_empty.sh"
expect "a red test's command is retired only where the record names the test" 1 "does not name it"
printf -- '- tests/red_empty.sh runs in the weekly job.\n' >> "$proj/docs/decisions/2026-10-24-red-weekly.md"
rec_commit "Intake: red-weekly names its test"
cp "$proj/src/tally/core.py" "$WORK/core.keep"
sed 's/^refuse_empty = True$//' "$WORK/core.keep" > "$proj/src/tally/core.py"
retire "sh tests/red_empty.sh"
expect "a failing proof is never retired; it regresses" 1 "fails now"
cp "$WORK/core.keep" "$proj/src/tally/core.py"
retire "sh tests/red_empty.sh"
expect "a proof is retired" 0 "is retired from match-one-month"
check "the command left the Proof block, a Retired line cites the record and the owner, the old entry is filed, all committed" '! grep -q "^    sh tests/red_empty.sh" "$proj/docs/done.md" && grep -q "^    sh tests/check.sh" "$proj/docs/done.md" && grep -q "^Retired: \`sh tests/red_empty.sh\` from the proof. See \`red-weekly\`. The owner said: \"Run it weekly instead.\"" "$proj/docs/done.md" && grep -q "sh tests/red_empty.sh" "$proj"/docs/decisions/sources/retired-match-one-month-*.md && [ "$(git -C "$proj" log -1 --format=%s)" = "serial-build: retire proof match-one-month" ] && [ -z "$(git -C "$proj" status --porcelain -- docs/done.md docs/decisions/sources)" ]'
script "$proj" check-canon.sh
expect "the rewritten entry carries a valid checksum" 0 "PASS  every done entry is as ship-gate.sh wrote it"
retire "sh tests/check.sh"
expect "a gate's last proof cannot be retired" 1 "is the last proof"
cp "$proj/docs/done.md" "$WORK/done.retired"
sed 's/^Accepted: .*/Accepted: "edited"/' "$WORK/done.retired" > "$proj/docs/done.md"
retire "sh tests/check.sh"
expect "nothing is retired from an entry changed by hand" 1 "not as ship-gate.sh wrote it"
git -C "$proj" reset -q HEAD~3
cp "$WORK/done.keep" "$proj/docs/done.md"
rm -f "$proj/docs/decisions/2026-10-24-red-weekly.md" "$proj"/docs/decisions/sources/retired-match-one-month-*.md
hook "$proj" session-start.sh '{"session_id":"s3"}'
expect "with no written-out gate left, session start names the next one-line gate" 0 "next one-line gate is two-accounts"
commit "$proj" "Handoff: match-one-month shipped"

echo "-- a red slug reused by the next gate (review item 5)"
{ printf '# two-accounts\n\nAcceptance: Ada reconciles two accounts in one run.\n\nProof:\n\n    sh tests/check.sh\n\nTried to break (the red lane attempts at least these):\n- an empty statement\n'
  printf '\n## Red\n\nRed run: 2026-10-05, 1 attempts, 1 findings. Source: `red-match-one-month-2026-10-02`.\n\n'
  printf -- '- red-empty-statement: the second account'"'"'s empty statement is dropped silently. Test: `tests/red_empty.sh@%s`. Reproduce: `sh tests/red_empty.sh`.\n\nAttempts that found nothing:\n- none\n' "$(git -C "$proj" hash-object tests/red_empty.sh)"; } > "$proj/docs/plan.md"
commit "$proj" "Red: two-accounts, 1 findings"
status; expect "the reused slug is judged on this plan's own record" 0 "1 of 1 red findings resolved"

echo "-- red-file: one call from the agents' output to a drafted Red run (issue 2)"
rf="$WORK/rf"
cp -R "$proj" "$rf"
today=$(date +%Y-%m-%d)
git -C "$rf" rm -q docs/plan.md && git -C "$rf" commit -qm "Handoff: two-accounts shipped"
printf '# rf-gate\n\nAcceptance: Ada can say it refuses an empty statement.\n\nProof:\n\n    sh tests/check.sh\n\nTried to break (the red lane attempts at least these):\n- an empty statement\n- a broken neighbour\n' > "$rf/docs/plan.md"
commit "$rf" "Plan: rf-gate"
script "$rf" red-guard.sh snapshot
wt3="$rf/.claude/worktrees/agent-rf"
git -C "$rf" worktree add -q -b worktree-agent-rf "$wt3" HEAD
printf 'grep -q fixed_one src/tally/core.py\n' > "$wt3/tests/red_rf_a.sh"
printf 'grep -q fixed_two src/tally/core.py\n' > "$wt3/tests/red_rf_c.sh"
printf 'exit 0\n' > "$wt3/tests/red_rf_b.sh"
cat > "$WORK/agent1.md" <<'EOF'
## Findings
- red-empty-statement: an empty statement crashes instead of being refused.
  Test: tests/red_rf_a.sh. Reproduce: `sh tests/red_rf_a.sh`.
  Seen: exit 1.
- red-rf-neighbour: a broken neighbour drops the valid file.
  Test: `tests/red_rf_c.sh`. Reproduce: `sh tests/red_rf_c.sh`.
  Seen: exit 1.
- red-rf-mirage: the header row is counted.
  Test: tests/red_rf_b.sh. Reproduce: `sh tests/red_rf_b.sh`.
  Seen: exit 1.

## Attempts that found nothing
- a file with only a header: refused, naming the missing rows.

## Files written
- tests/red_rf_a.sh
EOF
script "$rf" red-file.sh --output "$WORK/agent1.md" --worktree "$wt3" --cost "26 min, 1.4M tokens"
expect "red-file verifies, imports, files the output, and drafts the run" 0 "Red run: $today, 4 attempts, 2 findings. Source: \`red-rf-gate-$today\`. Cost: 26 min, 1.4M tokens."
check "each kept finding carries its test's blob hash" 'grep -q "^- red-empty-statement: an empty statement crashes instead of being refused. Test: \`tests/red_rf_a.sh@$(git -C "$rf" hash-object tests/red_rf_a.sh)\`. Reproduce: \`sh tests/red_rf_a.sh\`." "$rf/docs/plan.md"' "$(cat "$rf/docs/plan.md")"
check "a finding whose command passes when re-run is recorded as a fruitless attempt" 'grep -q "^- the header row is counted: re-run by red-file.sh, \`sh tests/red_rf_b.sh\` passed, so it is not a finding" "$rf/docs/plan.md"'
check "the raw output is filed verbatim, the worktree and its branch are gone, the lock is released" '[ -f "$rf/docs/decisions/sources/red-rf-gate-$today.md" ] && grep -q "red-rf-mirage" "$rf/docs/decisions/sources/red-rf-gate-$today.md" && [ ! -d "$wt3" ] && ! git -C "$rf" branch --list "worktree-agent-*" | grep -q . && [ ! -f "$(cd "$rf" && SB_ROOT=$(pwd) && SB_PLUGIN=$P && . "$S/lib.sh" && sb_red_lock)" ]'
rm -f "$rf/tests/red_rf_b.sh"
commit "$rf" "Red: rf-gate, 2 findings"
script "$rf" red-status.sh
expect "the drafted record is credible, and its findings open" 1 "2 of 2 red findings are open"
script "$rf" red-status.sh
expect "asking again on the same tree answers from memory" 1 "not re-run"
script "$rf" red-status.sh --fresh
case "$out" in *"not re-run"*) no "--fresh re-runs" "$out" ;; *) ok "--fresh re-runs" ;; esac

echo "-- red-pack: a generated context pack per lane (issue 3)"
mkdir -p "$rf/tests" && printf 'import pytest\n\n@pytest.fixture\ndef statement():\n    return []\n\ndef helper_x():\n    pass\n' > "$rf/tests/conftest.py"
mkdir -p "$rf/src/web" && echo 'route = 1' > "$rf/src/web/routes.py" && echo 'parse = 1' >> "$rf/src/tally/core.py"
commit "$rf" "build more"
sed 's|"red": { "test_paths": \["tests/\*\*"\] }|"red": { "test_paths": ["tests/**"], "test_command": "sh {file}", "lanes": [ { "name": "core", "focus": "the parser and its inputs", "paths": ["src/tally/**"] }, { "name": "web", "focus": "the routes" } ] }|' "$rf/.claude/serial-build.json" > "$WORK/cfg" && cp "$WORK/cfg" "$rf/.claude/serial-build.json"
script "$rf" check-config.sh
expect "check-config lists each lane, the first taking the timing attacks" 0 "red lane core: the parser and its inputs; also every subprocess and timing attack"
script "$rf" red-pack.sh core
expect "the pack names the gate, the lane, and the single-file test command" 0 "# Context pack: rf-gate, lane core"
check "the core lane gets its slice in full, and not the other lane's" 'printf "%s" "$out" | grep -q "^### src/tally/core.py" && ! printf "%s" "$out" | grep -q "^### src/web/routes.py" && printf "%s" "$out" | grep -q "^    sh {file}"' "$out"
check "the pack lists every changed file and the fixtures to reuse, but prints no test file as source" 'printf "%s" "$out" | grep -q "^- src/web/routes.py" && printf "%s" "$out" | grep -q "tests/conftest.py:3:@pytest.fixture" && ! printf "%s" "$out" | grep -q "^### tests/"' "$out"
script "$rf" red-pack.sh web
check "a lane with no paths gets every changed source file" 'printf "%s" "$out" | grep -q "^### src/web/routes.py" && printf "%s" "$out" | grep -q "^### src/tally/core.py"' "$out"
script "$rf" red-pack.sh nope
expect "an unknown lane is refused" 1 "no lane named"
git -C "$rf" checkout -q -- .claude/serial-build.json

echo "-- lanes: two breakers' outputs filed as one run (issue 3)"
script "$rf" red-guard.sh snapshot
wa="$rf/.claude/worktrees/agent-a" wb="$rf/.claude/worktrees/agent-b"
git -C "$rf" worktree add -q --detach "$wa" HEAD && git -C "$rf" worktree add -q --detach "$wb" HEAD
printf 'grep -q lane_a_fixed src/tally/core.py\n' > "$wa/tests/red_core_a.sh"
printf 'grep -q lane_b_fixed src/tally/core.py\n' > "$wb/tests/red_web_b.sh"
printf '## Findings\n- red-lane-bug: the core lane breaks it.\n  Test: tests/red_core_a.sh. Reproduce: `sh tests/red_core_a.sh`.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/lane1.md"
printf '## Findings\n- red-lane-bug: the web lane breaks it too.\n  Test: tests/red_web_b.sh. Reproduce: `sh tests/red_web_b.sh`.\n\n## Attempts that found nothing\n- b: nothing.\n' > "$WORK/lane2.md"
script "$rf" red-file.sh --output "$WORK/lane1.md" --output "$WORK/lane2.md" --worktree "$wa" --worktree "$wb" --cost "15 min, 0.8M tokens"
expect "two lanes become one run" 0 "4 attempts, 2 findings"
check "a slug two lanes both used is made unique, and the source holds both lanes" 'grep -q "^- red-lane-bug: the core lane" "$rf/docs/plan.md" && grep -q "^- red-lane-bug-2: the web lane" "$rf/docs/plan.md" && grep -q "^## Lane 2" "$rf"/docs/decisions/sources/red-rf-gate-$today-2.md'
git -C "$rf" reset -q --hard HEAD && git -C "$rf" clean -qfd -- tests docs
script "$rf" red-guard.sh abort

echo "-- red-file refuses rather than lose a finding (review of issues 2, 3)"
rf_reset() { git -C "$rf" reset -q --hard HEAD && git -C "$rf" clean -qfd -- tests docs; for w in "$rf"/.claude/worktrees/*; do [ -e "$w/.git" ] && git -C "$rf" worktree remove --force "$w"; done; script "$rf" red-guard.sh abort; }
script "$rf" red-guard.sh snapshot
printf '## Findings\n- red-total_off: the total is off by one.\n  Test: tests/x.sh. Reproduce: `sh tests/x.sh`.\n1. red-c\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/odd.md"
script "$rf" red-file.sh --output "$WORK/odd.md"
expect "a finding line it cannot read stops everything, naming it" 1 "1. red-c"
check "and nothing was done: the lock is still held, nothing filed" '! ls "$rf"/docs/decisions/sources/red-rf-gate-$today-2.md >/dev/null 2>&1 && git -C "$rf" diff --quiet -- docs/plan.md' 
wl="$rf/.claude/worktrees/agent-left"
git -C "$rf" worktree add -q --detach "$wl" HEAD && printf 'grep -q never src/tally/core.py\n' > "$wl/tests/red_left.sh"
printf '## Findings\n* red-Total_Off: the total is off by one.\n  Test: `tests/red_left.sh`. Reproduce: `sh tests/red_left.sh`.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/left.md"
script "$rf" red-file.sh --output "$WORK/left.md"
expect "an agent worktree with changes that was not passed stops everything" 1 "were not passed with --worktree"
script "$rf" red-file.sh --output "$WORK/left.md" --worktree "$wl"
expect "a near-miss bullet is read, its slug normalised" 0 "- red-total-off: the total is off by one."
script "$rf" red-status.sh --record
expect "red-status --record passes a well-formed uncommitted draft" 0 "well formed; commit it"
rf_reset
script "$rf" red-guard.sh snapshot
printf '## Findings\n- red-ghost: it breaks.\n  Test: tests/red_ghost.sh. Reproduce: `sh tests/red_ghost.sh`.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/ghost.md"
script "$rf" red-file.sh --output "$WORK/ghost.md"
expect "a finding whose test is not in the project is refused, not recorded as fruitless" 1 "tests are not in the project"
check "nothing was recorded for it" '! grep -q "red-ghost" "$rf/docs/plan.md"'
rf_reset
script "$rf" red-guard.sh snapshot
wm="$rf/.claude/worktrees/agent-m"
git -C "$rf" worktree add -q --detach "$wm" HEAD && printf 'grep -q never src/tally/core.py\n' > "$wm/tests/red_m.sh"
printf '## Findings\n- red-mutate: it breaks.\n  Test: tests/red_m.sh. Reproduce: `echo x >> src/tally/core.py; sh tests/red_m.sh`.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/mut.md"
script "$rf" red-file.sh --output "$WORK/mut.md" --worktree "$wm"
expect "a reproduce command that changes product code stops the filing" 1 "changed files that are not tests"
check "and names the file" 'printf "%s" "$out" | grep -q "src/tally/core.py"'
rf_reset

echo "-- red-pack --out and red-brief: the brief is a generated file, not retyped (issue 16)"
rfbase=$(git -C "$rf" rev-parse HEAD)
script "$rf" red-pack.sh --out "$rf/pack.md"
expect "red-pack refuses to write inside the project" 1 "outside the project"
script "$rf" red-pack.sh --out "$WORK/packs/p.md"
expect "red-pack writes the pack to a file outside the project" 0 "wrote the context pack"
check "the pack file holds the pack" 'grep -q "^# Context pack: rf-gate" "$WORK/packs/p.md"'
awk '{ print } /^Acceptance:/ { print ""; print "Supporting (built here though neither the demo nor the acceptance sentence needs it):"; print "- the consistency check: the next gate deploys with it" }' "$rf/docs/plan.md" > "$WORK/p" && cp "$WORK/p" "$rf/docs/plan.md"
commit "$rf" "Plan: name the supporting item"
script "$rf" red-brief.sh --out "$rf/brief"
expect "red-brief refuses to write inside the project" 1 "outside the project"
script "$rf" red-brief.sh --out "$WORK/rb"
expect "red-brief writes the brief and the pack, and prints the one line to brief with" 0 "Read $WORK/rb/brief.md and follow it"
check "the brief holds the gate, the attack order with the supporting item second, the pack's path, and the report form" 'grep -q "^Acceptance: Ada can say it refuses an empty statement." "$WORK/rb/brief.md" && grep -q "^1. The acceptance sentence" "$WORK/rb/brief.md" && grep -q "^- the consistency check" "$WORK/rb/brief.md" && grep -q "Read $WORK/rb/pack.md first" "$WORK/rb/brief.md" && grep -q "^## Findings" "$WORK/rb/brief.md" && grep -q "Kind: <the class of bug" "$WORK/rb/brief.md" && [ -f "$WORK/rb/pack.md" ]' "$(cat "$WORK/rb/brief.md")"
script "$rf" red-brief.sh --out "$WORK/rb" --delta
check "a delta brief is regressions only and lists the findings to re-attack (issue 13)" 'grep -q "A delta run: regressions only" "$WORK/rb/brief.md" && grep -q "red-empty-statement" "$WORK/rb/brief.md" && ! grep -q "^## Your minimum" "$WORK/rb/brief.md"'
script "$rf" red-brief.sh --out "$WORK/rb" --partial "the parser"
check "a partial brief names the finished slices (issue 14)" 'grep -q "these slices are finished: the parser" "$WORK/rb/brief.md"'

echo "-- red-file never files an unreadable report as clean (issue 17)"
script "$rf" red-guard.sh snapshot
printf '## Findings\n\n### red-heading: the total is off\n- Test: tests/a.sh\n- Reproduce: `sh tests/a.sh`\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/headings.md"
script "$rf" red-file.sh --output "$WORK/headings.md"
expect "a finding written as a heading stops everything" 1 "### red-heading"
wz="$rf/.claude/worktrees/agent-z"
git -C "$rf" worktree add -q --detach "$wz" HEAD && printf 'grep -q never src/tally/core.py\n' > "$wz/tests/red_z.sh"
printf 'Six things broke, see below.\n\n1) the total\n2) the header\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/prose.md"
script "$rf" red-file.sh --output "$WORK/prose.md" --worktree "$wz"
expect "tests came back but the report names no finding: nothing is recorded" 1 "brought back these test files"
check "and no clean run was filed" '! grep -q "Red run: .*, 1 attempts, 0 findings" "$rf/docs/plan.md"'
git -C "$rf" reset -q --hard "$rfbase" && git -C "$rf" clean -qfd -- tests docs; script "$rf" red-guard.sh abort

echo "-- kinds, intake items, the formatter on import, delta runs and the stop (issues 13, 17)"
printf '{"version":1,"owner":{"name":"Ada"},"inbox":"claude_outputs","checks":{"on_edit":[{"name":"fmt","paths":["tests/red_k*"],"run":"echo \\"# formatted\\" >> \\"$SB_FILE\\""}],"on_stop":[{"name":"tests","paths":["src/**","tests/**"],"run":"sh tests/check.sh"}]},"red":{"test_paths":["tests/**"]}}\n' > "$rf/.claude/serial-build.json"
commit "$rf" "a formatter for red tests"
script "$rf" red-guard.sh snapshot
wk="$rf/.claude/worktrees/agent-k"
git -C "$rf" worktree add -q --detach "$wk" HEAD && printf 'grep -q fixed_k1 src/tally/core.py\n' > "$wk/tests/red_k1.sh"
printf '## Findings\n- red-k1: a blank TALLY_HOME gives a traceback.\n  Kind: a bad startup variable is not refused by name.\n  Test: tests/red_k1.sh. Reproduce: `sh tests/red_k1.sh`.\n\n## For intake\n- the refusal says bad, not invalid.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/k1.md"
script "$rf" red-file.sh --output "$WORK/k1.md" --worktree "$wk" --delta
expect "a delta run with a kind is filed" 0 "a bad startup variable is not refused by name"
check "the kind and the delta mark are recorded, and the intake item is named, not filed" 'grep -q "^- red-k1: a blank TALLY_HOME gives a traceback. Kind: \`a bad startup variable is not refused by name\`. Test:" "$rf/docs/plan.md" && grep -q "^Red run: .* Delta run\." "$rf/docs/plan.md" && printf "%s" "$out" | grep -q "the refusal says bad, not invalid" && ! grep -q "refusal says bad" "$rf/docs/plan.md"' "$out"
check "the imported test went through the project's formatter before its fingerprint was taken" 'tail -n 1 "$rf/tests/red_k1.sh" | grep -q "# formatted" && grep -q "tests/red_k1.sh@$(git -C "$rf" hash-object tests/red_k1.sh)" "$rf/docs/plan.md"'
case "$out" in *STOP*) no "one delta run with findings does not stop the loop" "$out" ;; *) ok "one delta run with findings does not stop the loop" ;; esac
commit "$rf" "Red: rf-gate, delta 1"
script "$rf" red-guard.sh snapshot
git -C "$rf" worktree add -q --detach "$wk" HEAD && printf 'grep -q fixed_k2 src/tally/core.py\n' > "$wk/tests/red_k2.sh"
printf '## Findings\n- red-k2: an unset TALLY_HOME gives exit 0.\n  Kind: a bad startup variable is not refused by name.\n  Test: tests/red_k2.sh. Reproduce: `sh tests/red_k2.sh`.\n\n## Attempts that found nothing\n- a: nothing.\n' > "$WORK/k2.md"
script "$rf" red-file.sh --output "$WORK/k2.md" --worktree "$wk" --delta
expect "the second delta run with findings says to stop and ask about scope (issue 13)" 0 "STOP. This is the second delta run with findings"
git -C "$rf" reset -q --hard "$rfbase" && git -C "$rf" clean -qfd -- tests docs; script "$rf" red-guard.sh abort

echo "-- a partial run and the run after it meet the list together (issue 14)"
cp "$rf/docs/plan.md" "$WORK/plan.keep"
{ awk '/^## Red$/ { exit } { print }' "$WORK/plan.keep"
  printf '## Red\n\nRed run: 2026-10-25, 1 attempts, 0 findings. Source: `red-rf-gate-%s`. Partial run.\n\nAttempts that found nothing:\n- an empty statement: refused.\n\nRed run: 2026-10-25, 1 attempts, 0 findings. Source: `red-rf-gate-%s`. Delta run.\n\nAttempts that found nothing:\n- a broken neighbour: refused.\n' "$today" "$today"; } > "$rf/docs/plan.md"
script "$rf" red-status.sh --record
expect "a partial run plus the next run cover the two attempts" 0 "well formed"
sed 's/ Partial run\.//' "$rf/docs/plan.md" > "$WORK/p" && cp "$WORK/p" "$rf/docs/plan.md"
script "$rf" red-status.sh --record
expect "two ordinary runs of one attempt each do not" 1 "declares at least the 2 attempts"
cp "$WORK/plan.keep" "$rf/docs/plan.md"

echo "-- a voided run is recorded with the next filing, and the done entry states the cost (issue 2)"
script "$rf" red-guard.sh snapshot
echo planted >> "$rf/src/tally/core.py"
printf '## Findings\nFindings: none\n\n## Attempts that found nothing\n- a retry after a failure: the second run matched the first.\n' > "$WORK/agent2.md"
script "$rf" red-file.sh --output "$WORK/agent2.md" --cost "9 min, 0.5M tokens"
expect "a run red-guard voids records nothing in the project" 1 "the run is void and nothing was recorded"
check "no source was filed for the void" '[ ! -f "$rf/docs/decisions/sources/red-rf-gate-$today-2.md" ]'
git -C "$rf" checkout -q -- src/tally/core.py
script "$rf" red-guard.sh snapshot
script "$rf" red-file.sh --output "$WORK/agent2.md" --cost "12 min, 0.6M tokens"
expect "the next run is filed" 0 "Red run: $today, 1 attempts, 0 findings"
check "with the void recorded above it" 'grep -q "^Voided red run: $today, 9 min, 0.5M tokens. Why: src/tally/core.py changed, and it is not a test." "$rf/docs/plan.md"' "$(cat "$rf/docs/plan.md")"
commit "$rf" "Red: rf-gate, delta run"

echo "-- re-pinning several findings in one commit (issue 2)"
echo 'fixed_one = fixed_two = True' >> "$rf/src/tally/core.py"
printf '# moved\ngrep -q fixed_one src/tally/core.py\n' > "$rf/tests/red_rf_a.sh"
printf '# moved\ngrep -q fixed_two src/tally/core.py\n' > "$rf/tests/red_rf_c.sh"
echo "# Source: the breaker confirms both re-pinned tests" > "$rf/docs/decisions/sources/red-rf-confirm.md"
script "$rf" red-repin.sh red-empty-statement red-rf-neighbour --source red-rf-confirm
expect "two findings re-pin in one call" 0 "red-rf-neighbour re-pinned to tests/red_rf_c.sh@"
check "in one commit naming both" '[ "$(git -C "$rf" log -1 --format=%s)" = "serial-build: re-pin red-empty-statement red-rf-neighbour" ] && [ -z "$(git -C "$rf" status --porcelain -- tests docs/plan.md)" ]'
script "$rf" red-status.sh
expect "both resolve once the code is fixed" 0 "2 of 2 red findings resolved"
script "$rf" ship-gate.sh rf-gate --accepted "It refuses the empty one."
expect "the gate ships" 0 "moved to docs/done.md"
check "the done entry counts the voided run and states each run's cost" 'grep -q "over 2 run(s) and 1 voided run(s)" "$rf/docs/done.md" && grep -q "red lane cost: run 1: 26 min, 1.4M tokens; run 2: 12 min, 0.6M tokens; voided: $today, 9 min, 0.5M tokens" "$rf/docs/done.md"' "$(grep "Tried to break" "$rf/docs/done.md")"

echo "-- plan-draft: the next gate's plan drafted ahead, outside the project (issues 4, 6)"
printf '\n### next-gate\n\nBuilds: a summary line.\n\nDemo: Ada runs it. Break it: a broken file beside a valid one.\n\nDepends on: none.\n\nDecided: none.\n\nDecide by proof: none.\n\nOpen: none.\n\nQA: the summary is right.\n\nTried to break: a broken neighbour.\n\nAcceptance: Ada can say the summary is right.\n' >> "$rf/docs/roadmap.md"
commit "$rf" "Intake: next-gate written out"
script "$rf" plan-draft.sh status next-gate
expect "no draft yet" 1 "no draft of next-gate"
script "$rf" plan-draft.sh start nope
expect "only a written-out roadmap gate is drafted" 1 "no written-out gate"
script "$rf" red-guard.sh snapshot
script "$rf" plan-draft.sh start next-gate
expect "start cuts a branch and a worktree, and prints the launch command" 0 "/serial-build:gate --draft next-gate"
dwt=$(printf '%s\n' "$out" | sed -n 's/^plan-draft: the draft of next-gate will be written in \(.*\), on the branch.*/\1/p')
check "the draft worktree is outside the project" '[ -d "$dwt" ] && case "$dwt" in "$rf"/*) false ;; *) true ;; esac' "$dwt"
script "$rf" plan-draft.sh status next-gate
expect "a started draft is in progress until saved" 2 "in progress"
printf '# next-gate\n\nAcceptance: Ada can say the summary is right.\n\n- [ ] Add the summary to `src/tally/core.py`.\n\nProof:\n\n    sh tests/check.sh\n\nTried to break (the red lane attempts at least these):\n- a broken neighbour\n\nReview: two passes, no major finding on the second.\n' > "$dwt/docs/plan.md"
(cd "$dwt" && "$SHELL_UNDER_TEST" "$S/plan-draft.sh" save next-gate) > "$WORK/out" 2>&1; code=$?; out=$(cat "$WORK/out")
expect "the draft session saves its draft from its own worktree" 0 "is saved on serial-build/draft-next-gate"
script "$rf" red-guard.sh verify
expect "drafting during a red run does not void it" 0 "nothing but tests changed"
script "$rf" plan-draft.sh delta next-gate
expect "with nothing changed, the draft goes to the owner as reviewed" 0 "nothing the draft of next-gate depends on changed"
echo 'summary = 1' >> "$rf/src/tally/core.py"; commit "$rf" "fix from the demo"
script "$rf" plan-draft.sh delta next-gate
expect "a change to a file the draft names needs one review pass on the change" 3 "src/tally/core.py"
sed 's/^QA: the summary is right.$/QA: the summary is right, and totals match./' "$rf/docs/roadmap.md" > "$WORK/r" && cp "$WORK/r" "$rf/docs/roadmap.md"
script "$rf" plan-draft.sh delta next-gate
expect "so does a change to the gate's own roadmap section, such as a folded cleanup task (issue 5)" 3 "the next-gate section changed"
script "$rf" plan-draft.sh take next-gate
expect "take prints the draft" 0 "Add the summary to"
check "the project's own plan and branch are untouched by the draft" '[ ! -f "$rf/docs/plan.md" ] && [ "$(git -C "$rf" symbolic-ref --short HEAD)" != serial-build/draft-next-gate ]'
script "$rf" plan-draft.sh drop next-gate
expect "drop removes the draft" 0 "dropped"
check "the branch and worktree are gone" '! git -C "$rf" show-ref -q --verify refs/heads/serial-build/draft-next-gate && [ ! -d "$dwt" ]'
echo "-- plan-draft from a linked worktree, after a purged temp folder, and at a Later list (review of issue 4)"
lw="$WORK/rf-linked"
git -C "$rf" worktree add -q -b side "$lw" HEAD
printf '\n### side-gate\n\nBuilds: x.\n\nDemo: x. Break it: y.\n\nDepends on: none.\n\nDecided: none.\n\nDecide by proof: none.\n\nOpen: none.\n\nQA: x.\n\nTried to break: y.\n\nAcceptance: x.\n\nLater:\n- one-later: a later gate.\n' >> "$lw/docs/roadmap.md"
(cd "$lw" && git add -A && git commit -qm "side gate")
script "$lw" plan-draft.sh start side-gate
expect "a project that is itself a linked worktree drafts from its own roadmap" 0 "/serial-build:gate --draft side-gate"
sdw=$(printf '%s\n' "$out" | sed -n 's/^plan-draft: the draft of side-gate will be written in \(.*\), on the branch.*/\1/p')
hook "$sdw" session-start.sh '{"session_id":"d1","source":"startup"}'
expect "session start inside a draft worktree names the draft, not the active gate" 0 "drafted ahead"
printf '# side-gate\n\nAcceptance: x.\n' > "$sdw/docs/plan.md"
(cd "$sdw" && "$SHELL_UNDER_TEST" "$S/plan-draft.sh" save side-gate) > "$WORK/out" 2>&1; code=$?; out=$(cat "$WORK/out")
expect "the draft session saves back to the linked worktree it came from" 0 "is saved"
printf -- '- two-later: another.\n' >> "$lw/docs/roadmap.md"
script "$lw" plan-draft.sh delta side-gate
expect "a gate written out under the stage's Later list is not a change to the drafted gate" 0 "nothing the draft of side-gate depends on changed"
rm -rf "$sdw"
script "$lw" plan-draft.sh drop side-gate
expect "drop works after the temp folder was purged" 0 "dropped"
check "and the branch is really gone" '! git -C "$rf" show-ref -q --verify refs/heads/serial-build/draft-side-gate'
git -C "$rf" worktree remove --force "$lw"

git -C "$rf" checkout -q -- docs/roadmap.md

echo "-- ship-gate --regress keeps the gate in the ledger (review item 6)"
cp "$proj/docs/roadmap.md" "$WORK/roadmap.keep"; cp "$proj/docs/done.md" "$WORK/done.keep2"
printf '# Roadmap\n\nRole: pending gates only.\n' > "$proj/docs/roadmap.md"
ship --regress match-one-month --failed "tests/check.sh: 1 failed"
expect "regress onto a roadmap with no stage heading succeeds" 0 "regression gate"
check "the gate landed under a new regressions stage and left done" 'grep -qx "### match-one-month" "$proj/docs/roadmap.md" && grep -qx "## Stage: regressions" "$proj/docs/roadmap.md" && ! grep -q "^## match-one-month" "$proj/docs/done.md"'
cp "$WORK/done.keep2" "$proj/docs/done.md"
printf '# Roadmap\n\nRole: pending gates only.\n\n## Stage: regressions\n\n### older-gate\n\nBuilds: x\n' > "$proj/docs/roadmap.md"
rm -f "$proj"/docs/decisions/sources/regression-match-one-month*.md
ship --regress match-one-month --failed "tests/check.sh: 1 failed"
check "a regressions stage without a Goal line gains one, with the gate first" 'grep -q "^Goal: every shipped gate" "$proj/docs/roadmap.md" && [ "$(awk "/^### /{print; exit}" "$proj/docs/roadmap.md")" = "### match-one-month" ] && ! grep -q "^## match-one-month" "$proj/docs/done.md"'
cp "$WORK/roadmap.keep" "$proj/docs/roadmap.md"; cp "$WORK/done.keep2" "$proj/docs/done.md"
rm -f "$proj"/docs/decisions/sources/regression-match-one-month*.md
ship --regress match-one-month --failed "tests/check.sh: 1 failed"
expect "a failing proof moves the gate back as a regression gate" 0 "regression gate"
check "the done entry is gone and the roadmap has the regression gate first" '! grep -q "^## match-one-month" "$proj/docs/done.md" && [ "$(awk "/^### /{print; exit}" "$proj/docs/roadmap.md")" = "### match-one-month" ] && [ -f "$proj/docs/decisions/sources/regression-match-one-month.md" ]'
rm -f "$proj/docs/plan.md"
script "$proj" check-canon.sh
expect "the ledger passes the canon check after a regression" 0 "PASS  every roadmap gate has"

# ---------------------------------------------------------------- monorepo
echo "-- a project in a subfolder of a larger repository (review item 7)"
mono="$WORK/mono"
mkdir -p "$mono/app" "$mono/other" && (cd "$mono" && git init -q && echo x > other/readme.txt)
render "$FIX/answers.json" "$mono/app"
mkdir -p "$mono/app/src/tally" "$mono/app/tests" && printf 'exit 0\n' > "$mono/app/tests/check.sh" && echo 'x = 1' > "$mono/app/src/tally/core.py"
commit "$mono" init
echo 'y = 2' >> "$mono/app/src/tally/core.py"
hook "$mono/app" stop-checks.sh '{"session_id":"m1","stop_hook_active":false}'
expect "stop checks see changes in the subproject" 0 "tests passed"
git -C "$mono" checkout -q -- .
script "$mono/app" red-guard.sh snapshot
expect "red-guard runs from the subproject" 0 "snapshot at"
echo 'assert 0' > "$mono/app/tests/red_x.sh"
script "$mono/app" red-guard.sh verify
expect "verify reads test paths relative to the subproject" 0 "tests/red_x.sh"
(cd "$mono" && git worktree add -q --detach "$WORK/mwt" HEAD)
hook "$mono/app" red-fence.sh "$(red_input Write "\"file_path\":\"$WORK/mwt/app/tests/test_red.py\"")"; silent "the fence maps the worktree to the subproject"

# ---------------------------------------------------------------- configs
echo "-- broken and switched-off configs"
cp "$proj/.claude/serial-build.json" "$WORK/good.json"
printf '{"version": 1, "owner": ' > "$proj/.claude/serial-build.json"
hook "$proj" guard-generated.sh "$(write_input "$proj/src/tally/_version.py")"; silent "a malformed config switches the guard off, silently"
hook "$proj" session-start.sh '{"session_id":"s3"}'
expect "session start reports the malformed config" 0 "not valid JSON"
sed 's/"version": 1,/"version": 1, "enabled": false,/' "$WORK/good.json" > "$proj/.claude/serial-build.json"
hook "$proj" guard-generated.sh "$(write_input "$proj/src/tally/_version.py")"; silent "enabled: false switches the guard off"
hook "$proj" session-start.sh '{"session_id":"s3"}'; silent "enabled: false silences session start"

printf '{"version":1,"owner":{"name":"Ada"},"red":{"test_paths":["tests/**"],"test_command":"sh {file}"}}' > "$WORK/tc.json"
script "$proj" check-config.sh "$WORK/tc.json"
expect "check-config names the red lane's single-file test command (issue 3)" 0 'runs one test file with `sh {file}`'
printf '{"version":1,"owner":{"name":"Ada"},"red":{"test_paths":["tests/**"],"test_command":"make test"}}' > "$WORK/tc.json"
script "$proj" check-config.sh "$WORK/tc.json"
expect "check-config warns when red.test_command has no {file} (issue 3)" 0 'has no {file}'

echo "-- the skills and agents say what the scripts cannot enforce"
check "/red demotes only on the owner's answer to AskUserQuestion, passed verbatim (third review, item 2)" 'grep -q "Ask the owner with AskUserQuestion" "$P/skills/red/SKILL.md" && grep -q "their answer, verbatim" "$P/skills/red/SKILL.md" && grep -q "never this session on its own judgement" "$P/skills/red/SKILL.md"'
check "README says the demotion check stops accidents, not a determined forger (third review, item 2)" 'grep -q "not a determined forger" "$REPO/README.md"'
check "the breaker is told to write tests with the Write tool, not shell redirects (third review, item 4)" 'grep -q "Write each test file with the Write tool, never a Bash heredoc or redirect" "$P/agents/red-breaker.md"'
check "intake commits, then summarises, and waits only for glossary entries and contradictions (issue 9)" 'grep -q "Stop and wait before committing in exactly two cases" "$P/skills/intake/SKILL.md" && ! grep -q "Commit on approval" "$P/skills/intake/SKILL.md"'
check "gate steps 2 to 4 never ask the owner (issue 9)" 'grep -q "Steps 2 to 4 never call AskUserQuestion" "$P/skills/gate/SKILL.md"'
check "the gate template runs the demo before the red task (issue 8)" 'awk "/Run the demo end to end/ { d = NR } /Run \/serial-build:red on this gate/ { r = NR } END { exit !(d && r && d < r) }" "$P/skills/gate/SKILL.md"'
check "the red skill runs from a fresh session and has a post-fix delta run (issues 2, 3)" 'grep -q "Run this skill in a fresh session" "$P/skills/red/SKILL.md" && grep -q "## 9. The fix and delta loop, chained" "$P/skills/red/SKILL.md"'
check "the breaker carries the rules against re-pins (issue 3)" 'grep -q "One finding per test file" "$P/agents/red-breaker.md" && grep -q "at least 5x the measured latency" "$P/agents/red-breaker.md"'
check "intake folds a cleanup-only finding into the next product gate, stating the cost (issue 5)" 'grep -q "^f. \*\*Cleanup only\*\*" "$P/skills/intake/SKILL.md" && grep -q "blocks that" "$P/skills/intake/SKILL.md"'
check "handoff starts the next gate's draft without asking, and never a building session (issue 6)" 'grep -q "start drafting it" "$P/skills/handoff/SKILL.md" && grep -q "without asking" "$P/skills/handoff/SKILL.md" && grep -q "Never launch a background session that builds" "$P/skills/handoff/SKILL.md"'
check "gate takes a waiting draft through the delta check (issue 4)" 'grep -q "plan-draft.sh delta" "$P/skills/gate/SKILL.md" && grep -q "\-\-draft <gate-slug>" "$P/skills/gate/SKILL.md"'
check "the red skill chains fix and delta runs through fresh agents, stopping on a second delta with findings (issues 13, 15)" 'grep -q "serial-build:red-fixer" "$P/skills/red/SKILL.md" && grep -q "STOP" "$P/skills/red/SKILL.md" && [ -f "$P/agents/red-fixer.md" ] && grep -q "Never edit a red test" "$P/agents/red-fixer.md" && grep -q "table-driven test" "$P/agents/red-fixer.md"'
check "the red skill allows a partial run while the builder waits outside the repo (issue 14)" 'grep -q "A partial run, earlier" "$P/skills/red/SKILL.md" && grep -q "partial red run" "$P/skills/gate/SKILL.md"'
check "the gate review asks of every item whether the demo or acceptance needs it (issue 18)" 'grep -q "does the demo or the" "$P/skills/gate/SKILL.md" && grep -q "^Supporting (built here" "$P/skills/gate/SKILL.md"'
missing_next=$(for k in gate intake red demo-brief handoff; do grep -q "next" "$P/skills/$k/SKILL.md" || printf "%s " "$k"; done)
check "every step names the next command (issue 6)" '[ -z "$missing_next" ] && grep -q "next: \`/clear\`" "$P/skills/gate/SKILL.md"' "$missing_next"

echo "-- the version (an unchanged version is not picked up by /plugin update)"
pv=$(jget "$P/.claude-plugin/plugin.json" version)
mv_=$(jget "$REPO/.claude-plugin/marketplace.json" plugins.0.version)
check "plugin.json and the marketplace entry carry the same version ($pv, $mv_)" '[ -n "$pv" ] && [ "$pv" = "$mv_" ]'

echo "-- the README"
fields=$(grep -o '^| `[a-z_.]*`' "$P/skills/scope/references/config.md" | tr -d '|` ')
undocumented=$(for f in $fields; do grep -q "\`$f\`" "$REPO/README.md" || printf '%s ' "$f"; done)
check "README covers every config field" '[ -z "$undocumented" ]' "$undocumented"
check "README documents a local install (review item 9)" 'grep -q "marketplace add /path/to/serial-build-harness" "$REPO/README.md"'
check "README's lint example lints the edited file only (review item 13)" 'grep -q "npx eslint --quiet \\\\\"\$SB_FILE\\\\\"" "$REPO/README.md" && grep -q "npx eslint --quiet \\\\\"\$SB_FILE\\\\\"" "$P/skills/scope/references/config.md"'
check "README warns that committed red tests fail CI (review item 16)" 'grep -qi "continuous integration" "$REPO/README.md"'
check "README says to use the full name when handoff collides (review item 19)" 'grep -q "/serial-build:handoff" "$REPO/README.md" && grep -qi "collide" "$REPO/README.md"'

echo
echo "$pass passed, $fail failed ($SHELL_UNDER_TEST)"
[ "$fail" -eq 0 ]
