#!/bin/sh
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit|Bash: the red lock. While the
# red-breaker agent runs, anything else that writes into the project voids its run
# (red-guard.sh verify sees the change and cannot tell it from the breaker's): a
# builder session that keeps working, a test run that rewrites an ignored cache.
# The harness may run the breaker in the background, so an instruction to wait
# cannot hold by itself; this hook makes the wait.
#
# The lock is held from "red-guard.sh snapshot" until "red-guard.sh verify" or
# "red-guard.sh abort" (a marker in the repository's shared .git, never in the
# project, and not in the temp folder, which the hook and the shell may not share). While it is held, for every caller but the red-breaker agent:
#   - Edit, Write, MultiEdit, and NotebookEdit under the project are refused,
#     agent worktrees included; outside the project they pass.
#   - Bash is refused unless it is the red-guard, red-file, or red-pack script, or every
#     command in it is on a short read-only list (ls, cat, grep, find without
#     -exec or -delete, read-only git without -c or --output, ps, kill, and the
#     like) with no output
#     redirect other than to /dev/null. An allowlist, because guessing whether
#     an arbitrary command writes is a game a list of refusals loses.
# No config, or no lock: exit 0, silent.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/../.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
sb_load_config || exit 0
lock=$(sb_red_lock) || exit 0
[ -f "$lock" ] || exit 0

input=$(sb_read_input "agent_type tool_name tool_input.file_path tool_input.notebook_path tool_input.command")
agent=$(sb_get "$input" agent_type) || agent=
case "$agent" in *red-breaker) exit 0 ;; esac
tool=$(sb_get "$input" tool_name) || tool=
held="The red lock is held: the red-breaker agent is attacking this project, and any other write into it voids the run. Wait for it to finish, then run red-guard.sh verify (or red-file.sh), which releases the lock. If the run hung or a session died holding the lock, release it and void the run with: sh \"$SB_PLUGIN/scripts/red-guard.sh\" abort"

if [ "$tool" = Bash ]; then
  cmd=$(sb_get "$input" tool_input.command) || exit 0
  # The red lane's own scripts, invoked plainly with simple arguments.
  # The script path is one word: quoted whole, or with no space in it.
  if printf '%s\n' "$cmd" | grep -Eq '^[[:space:]]*(sh[[:space:]]+)?("[^"$`;&|<>()]*/scripts/red-(guard|file|pack)\.sh"|[^[:space:]"$`;&|<>()'"'"']*/scripts/red-(guard|file|pack)\.sh)([[:space:]]+("[^"$`]*"|[^[:space:];&|<>`()$"'"'"']+))*[[:space:]]*$'; then
    exit 0
  fi
  bad=$(printf '%s\n' "$cmd" | sed 's#[0-9]*>[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9]##g; s#&>[[:space:]]*/dev/null##g' | LC_ALL=C awk '
    BEGIN {
      # Nothing here writes a file, whatever its options (sort -o, uniq OUT,
      # less -o, file -C, rg --pre, and date -s are why those are not here).
      split("ls cat head tail grep egrep fgrep wc stat pwd echo printf true false test [ which type sleep du df ps pgrep kill pkill jobs wait basename dirname realpath readlink cut tr cmp", a, " ")
      for (i in a) ok[a[i]] = 1
      split("status log diff show rev-parse ls-files ls-tree blame grep hash-object cat-file describe shortlog show-ref rev-list merge-base check-ignore version", g, " ")
      for (i in g) gitok[g[i]] = 1
    }
    /[>]/ { print "an output redirect"; exit }
    { gsub(/["\\\047]/, ""); n = split($0, seg, /[;&|()`$<{}]/)
      for (s = 1; s <= n; s++) {
        m = split(seg[s], w, /[ \t]+/); i = 1
        while (i <= m && w[i] == "") i++
        while (i <= m && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
        if (i > m) continue
        c = w[i]; sub(/.*\//, "", c)
        if (c == "git") {
          j = i + 1
          while (j <= m && w[j] ~ /^-/) { if (w[j] ~ /^-c/ || w[j] ~ /^--config-env/) { print "git -c"; exit } if (w[j] == "-C") j++; j++ }
          for (k = j + 1; k <= m; k++) if (w[k] ~ /^--output/ || w[k] ~ /^--ext-diff/ || w[k] == "-o") { print "git " w[j] " " w[k]; exit }
          if (w[j] in gitok) continue
          if ((w[j] == "worktree" || w[j] == "stash") && w[j + 1] == "list") continue
          if (w[j] == "branch" && w[j + 1] == "--show-current") continue
          print "git " w[j]; exit
        }
        if (c == "find") {
          for (j = i + 1; j <= m; j++) if (w[j] ~ /^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/) { print "find " w[j]; exit }
          continue
        }
        if (!(c in ok)) { print c; exit }
      }
    }')
  if [ -n "$bad" ]; then
    printf '%s\n"%s" is refused while it is held (%s is not on the read-only list).\n' "$held" "$cmd" "$bad" >&2
    exit 2
  fi
  exit 0
fi

path=$(sb_get "$input" tool_input.file_path) || path=$(sb_get "$input" tool_input.notebook_path) || exit 0
case "$path" in "$SB_ROOT"|"$SB_ROOT"/*) ;; *) exit 0 ;; esac
printf '%s\nA write to %s is refused while it is held.\n' "$held" "$(sb_rel "$path")" >&2
exit 2
