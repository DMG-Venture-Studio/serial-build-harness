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
#   - Bash is refused unless it is the red-guard, red-file, red-pack, or
#     red-brief script, or every command in it is on a read-only list (ls, cat,
#     grep, find without -exec or -delete, read-only git and gh, ps, kill, and
#     the like) and every output redirect or tee goes to /dev/null or to an
#     absolute path outside the project, its repository, and the shared .git.
#     An allowlist, because guessing whether an arbitrary command writes is a
#     game a list of refusals loses.
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
  if printf '%s\n' "$cmd" | grep -Eq '^[[:space:]]*(sh[[:space:]]+)?("[^"$`;&|<>()]*/scripts/red-(guard|file|pack|brief)\.sh"|[^[:space:]"$`;&|<>()'"'"']*/scripts/red-(guard|file|pack|brief)\.sh)([[:space:]]+("[^"$`]*"|[^[:space:];&|<>`()$"'"'"']+))*[[:space:]]*$'; then
    exit 0
  fi
  # Folders a write must stay out of: the project (as given and resolved), the
  # repository's top, and its shared .git.
  roots="$SB_ROOT
$(cd "$SB_ROOT" && pwd -P)
$(git -C "$SB_ROOT" rev-parse --show-toplevel 2>/dev/null)
$(cd "$SB_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  bad=$(printf '%s\n' "$cmd" | sed 's#[0-9]*>[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9]##g; s#&>[[:space:]]*/dev/null##g' | SB_ROOTS=$roots LC_ALL=C awk '
    BEGIN {
      # Nothing here writes a file. Commands that can, only with certain
      # options or operands (sort -o, uniq IN OUT, date -s, rg --pre), are
      # checked below; less, file, sed, and awk are left off altogether.
      split("ls cat head tail grep egrep fgrep wc stat pwd echo printf true false test [ which type sleep du df ps pgrep kill pkill jobs wait basename dirname realpath readlink cut tr cmp jq md5sum shasum sha1sum sha256sum cksum id whoami uname hostname printenv nl tac rev column", a, " ")
      for (i in a) ok[a[i]] = 1
      split("status log diff show rev-parse ls-files ls-tree blame grep hash-object cat-file describe shortlog show-ref rev-list merge-base check-ignore version whatchanged count-objects name-rev for-each-ref", g, " ")
      for (i in g) gitok[g[i]] = 1
      nr = split(ENVIRON["SB_ROOTS"], root, "\n")
    }
    # outside(p): an absolute path, with no .. or variable, in none of the roots.
    function outside(p,   r) {
      if (p !~ /^\// || p ~ /(^|\/)\.\.(\/|$)/ || p ~ /[$`~*?]/) return 0
      for (r = 1; r <= nr; r++) if (root[r] != "" && (p == root[r] || index(p, root[r] "/") == 1)) return 0
      return 1
    }
    {
      # A redirect to a file outside the project is allowed; any other is not.
      line = $0
      while (match(line, /[0-9]*>>?[ \t]*("[^"]*"|\047[^\047]*\047|[^ \t;&|<>()]+)/)) {
        t = substr(line, RSTART, RLENGTH); sub(/^[0-9]*>>?[ \t]*/, "", t); gsub(/["\047]/, "", t)
        if (!outside(t)) { print "an output redirect to " t " (only a path outside the project may be written)"; exit }
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
      if (line ~ />/) { print "an output redirect"; exit }
      gsub(/["\\\047]/, "", line); n = split(line, seg, /[;&|()`$<{}]/)
      for (s = 1; s <= n; s++) {
        m = split(seg[s], w, /[ \t]+/); i = 1
        while (i <= m && w[i] == "") i++
        while (i <= m && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
        if (i > m) continue
        c = w[i]; sub(/.*\//, "", c)
        if (c == "git") {
          j = i + 1
          while (j <= m && w[j] ~ /^-/) { if (w[j] ~ /^-c/ || w[j] ~ /^--config-env/ || w[j] ~ /^--exec-path/) { print "git " w[j]; exit } if (w[j] == "-C" || w[j] == "--git-dir" || w[j] == "--work-tree") j++; j++ }
          for (k = j + 1; k <= m; k++) if (w[k] ~ /^--output/ || w[k] ~ /^--ext-diff/ || w[k] == "-o") { print "git " w[j] " " w[k]; exit }
          sub_ = w[j]; nx = w[j + 1]
          if (sub_ in gitok) continue
          if ((sub_ == "worktree" || sub_ == "stash") && nx == "list") continue
          if (sub_ == "stash" && nx == "show") continue
          if (sub_ == "remote" && (nx == "" || nx == "-v" || nx == "get-url" || nx == "show")) continue
          if (sub_ == "tag" && (nx == "" || nx == "-l" || nx == "--list")) continue
          if (sub_ == "reflog" && (nx == "" || nx == "show" || nx ~ /^-/)) continue
          if (sub_ == "config") { for (k = j + 1; k <= m; k++) if (w[k] ~ /^(--get|--get-all|--get-regexp|--list|-l)$/) break; if (k <= m) continue }
          if (sub_ == "branch") { for (k = j + 1; k <= m; k++) if (w[k] !~ /^(--show-current|--list|-l|-a|--all|-r|--remotes|-v|-vv|--verbose|--contains|--merged|--no-merged)$/) break; if (k > m) continue }
          print "git " sub_; exit
        }
        if (c == "gh") {
          j = i + 1
          while (j <= m && w[j] ~ /^-/) { if (w[j] == "-R" || w[j] == "--repo") j++; j++ }
          g1 = w[j]; g2 = w[j + 1]
          if (g1 == "status" || (g1 == "auth" && g2 == "status")) continue
          if ((g1 == "run" || g1 == "issue" || g1 == "workflow" || g1 == "release") && (g2 == "list" || g2 == "view")) continue
          if (g1 == "pr" && (g2 == "list" || g2 == "view" || g2 == "diff" || g2 == "checks" || g2 == "status")) continue
          if (g1 == "repo" && g2 == "view") continue
          print "gh " g1 " " g2; exit
        }
        if (c == "find") {
          for (j = i + 1; j <= m; j++) if (w[j] ~ /^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/) { print "find " w[j]; exit }
          continue
        }
        if (c == "sort") { for (j = i + 1; j <= m; j++) if (w[j] ~ /^(-o|--output)/ || w[j] ~ /^-[a-zA-Z]*o/) { print "sort " w[j]; exit } continue }
        if (c == "uniq") { o = 0; for (j = i + 1; j <= m; j++) if (w[j] !~ /^-/ && w[j] != "") o++; if (o > 1) { print "uniq with an output file"; exit } continue }
        if (c == "date") { for (j = i + 1; j <= m; j++) if (w[j] ~ /^(-s|--set)/) { print "date " w[j]; exit } continue }
        if (c == "rg") { for (j = i + 1; j <= m; j++) if (w[j] ~ /^--pre/) { print "rg " w[j]; exit } continue }
        if (c == "tee") { for (j = i + 1; j <= m; j++) if (w[j] != "" && w[j] !~ /^-/ && !outside(w[j])) { print "tee to " w[j] " (only a path outside the project may be written)"; exit } continue }
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
