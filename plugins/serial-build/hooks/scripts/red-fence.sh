#!/bin/sh
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit|Bash: an early, advisory fence
# around the red-breaker agent, the subagent that tries to break a gate. Its only
# admissible output is a failing test; if it could edit the code under test, a
# "finding" could be a bug it planted. The guarantee is elsewhere: the agent works
# in its own git worktree, red-import.sh copies back only its tests, and
# red-guard.sh voids the run if anything else changed. This hook stops the obvious
# attempts early, so the run is not wasted.
#
# Acts only when the hook input's agent_type names the red-breaker agent (Claude
# Code sends "serial-build:red-breaker"); every other caller, in any repository,
# passes untouched. For that agent:
#   - a file write must match "red.test_paths" in .claude/serial-build.json,
#     measured from the project's place in whichever worktree it writes to;
#   - git, where it is the command being run, may run only read-only forms
#     (status, diff, log, show, stash list, branch --show-current, worktree
#     list, reflog, and the like); anything else, including aliases, is refused.
#     Git named inside an argument (grep "git commit") is not a command.
# With no config there are no test paths, so every write is refused.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"

input=$(sb_read_input "agent_type tool_name tool_input.file_path tool_input.notebook_path tool_input.command")
agent=$(sb_get "$input" agent_type) || exit 0
case "$agent" in *red-breaker) ;; *) exit 0 ;; esac
tool=$(sb_get "$input" tool_name) || tool=

if [ "$tool" = Bash ]; then
  cmd=$(sb_get "$input" tool_input.command) || exit 0
  # Drop quotes and backslashes (so "git" commit and g\it commit read as git
  # commit) and split into commands at ; & | ( ) ` $ < > { } and newlines. Git is
  # judged where it is the command: first word; after VAR=value, after a wrapper
  # (env, sudo, doas, command, exec, eval, nohup, time, timeout, nice, ionice,
  # stdbuf, xargs) and its options and numeric arguments; as the command a shell
  # runs with -c (or a flag cluster holding c, such as -lc); and after find's
  # -exec. Git named inside an argument (grep "git commit") is not a command.
  # This is advisory: an alias, a script file, or a variable holding "git" gets
  # past it, and red-guard.sh and red-import.sh catch what that changes.
  bad=$(printf '%s\n' "$cmd" | tr -d '"\\'"'" | tr ';&|()`$<>{}' '\n\n\n\n\n\n\n\n\n\n\n' | LC_ALL=C awk '
    BEGIN {
      split("status diff log show ls-files ls-tree rev-parse blame grep hash-object cat-file describe shortlog show-ref for-each-ref rev-list name-rev merge-base check-ignore var version help whatchanged count-objects", a, " ")
      for (i in a) always[a[i]] = 1
      split("env sudo doas command exec eval nohup time timeout nice ionice stdbuf xargs", w, " "); for (i in w) wrapper[w[i]] = 1
      # Options that take a separate argument, per wrapper (sudo -i and -s take none).
      split("sudo -u|sudo -g|sudo -C|sudo -p|sudo -h|doas -u|doas -C|nice -n|timeout -s|timeout -k|env -u|env -C|env -S|ionice -c|ionice -n|ionice -p|xargs -n|xargs -P|xargs -I|xargs -L|xargs -E|xargs -s|xargs -d|xargs -a|stdbuf -i|stdbuf -o|stdbuf -e", o, "|")
      for (i in o) takesarg[o[i]] = 1
      split("sh bash dash zsh ksh", sh, " "); for (i in sh) shell[sh[i]] = 1
    }
    function base(x) { sub(/.*\//, "", x); return x }
    # judge(i): words i.. are a git command line; prints the refused form, if any.
    function judge(i,   sub_, j, rest, k) {
      while (i <= NF && $i ~ /^-/) { if ($i == "-C" || $i == "-c" || $i == "--git-dir" || $i == "--work-tree") i++; i++ }
      if (i > NF) return ""
      sub_ = $i; rest = ""
      for (k = i + 1; k <= NF; k++) rest = rest " " $k
      if (sub_ in always) return ""
      if (sub_ == "stash" && ($(i + 1) == "list" || $(i + 1) == "show")) return ""
      if (sub_ == "worktree" && $(i + 1) == "list") return ""
      if (sub_ == "notes" && ($(i + 1) == "list" || $(i + 1) == "show")) return ""
      if (sub_ == "reflog" && (i == NF || $(i + 1) == "show" || $(i + 1) ~ /^-/)) return ""
      if (sub_ == "remote" && (i == NF || $(i + 1) == "-v" || $(i + 1) == "show" || $(i + 1) == "get-url")) return ""
      if (sub_ == "tag" && (i == NF || $(i + 1) == "-l" || $(i + 1) == "--list")) return ""
      if (sub_ == "config" && rest ~ / (--get|--get-all|--get-regexp|--list|-l)( |$)/) return ""
      if (sub_ == "branch") {
        for (k = i + 1; k <= NF; k++) {
          if ($k ~ /^(-d|-D|-m|-M|-c|-C|-f|-u|--force|--delete|--move|--copy|--set-upstream-to.*|--unset-upstream|--edit-description)$/) return "branch" rest
          if ($k !~ /^-/) return "branch" rest
        }
        return ""
      }
      return sub_ rest
    }
    # cmdat(i): the command that starts at word i; prints a refused git form and exits.
    function cmdat(i,   j, r, wr) {
      while (i <= NF) {
        if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (base($i) in wrapper) {
          wr = base($i); i++
          while (i <= NF && ($i ~ /^-/ || $i ~ /^[0-9.]+[smhd]?$/ || $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) { if ((wr " " $i) in takesarg) i++; i++ }
          continue
        }
        break
      }
      if (i > NF) return
      if (base($i) in shell) {
        for (j = i + 1; j <= NF && $j !~ /^-[A-Za-z]*c[A-Za-z]*$/; j++);
        if (j < NF) cmdat(j + 1)
        return
      }
      if (base($i) == "git") { r = judge(i + 1); if (r != "") { print r; exit } }
    }
    {
      cmdat(1)
      for (k = 1; k < NF; k++) if ($k == "-exec" || $k == "-execdir" || $k == "-ok" || $k == "-okdir") cmdat(k + 1)
    }')
  if [ -n "$bad" ]; then
    printf 'The red-breaker agent may run only read-only git commands (status, diff, log, show, and the like); "git %s" is refused: %s\nThe /serial-build:red skill commits the failing test after checking it; report the test path and the command that reproduces the failure instead.\n' "$bad" "$cmd" >&2
    exit 2
  fi
  exit 0
fi

path=$(sb_get "$input" tool_input.file_path) || path=$(sb_get "$input" tool_input.notebook_path) || exit 0
if ! sb_load_config; then
  printf 'The red-breaker agent writes only under the project'"'"'s test paths, and this project has no .claude/serial-build.json naming them ("red.test_paths"), so %s is refused.\n' "$path" >&2
  exit 2
fi
rel=$(sb_rel_project "$path")
case "$rel" in /*) ;; *)
  if [ "$(sb_count "$SB_CFG" red.test_paths)" -gt 0 ] && sb_match_any "$rel" "$SB_CFG" red.test_paths; then exit 0; fi ;;
esac
printf 'The red-breaker agent writes tests only, and %s is not under the test paths in .claude/serial-build.json ("red.test_paths"). Its output is a failing test or "nothing found"; it never edits the code under test. To try something destructive, copy the worktree with Bash (cp -R into a mktemp -d folder) and work there.\n' "$rel" >&2
exit 2
