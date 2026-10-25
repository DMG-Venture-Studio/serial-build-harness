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
  # The red lane's own scripts, this plugin's copies only, invoked plainly with
  # simple arguments. The script path is one word: quoted whole, or no space.
  if printf '%s\n' "$cmd" | grep -Eq '^[[:space:]]*(sh[[:space:]]+)?("[^"$`;&|<>()]*/scripts/red-(guard|file|pack|brief)\.sh"|[^[:space:]"$`;&|<>()'"'"']*/scripts/red-(guard|file|pack|brief)\.sh|"?\$\{?CLAUDE_PLUGIN_ROOT\}?/scripts/red-(guard|file|pack|brief)\.sh"?)([[:space:]]+("[^"$`]*"|[^[:space:];&|<>`()$"'"'"']+))*[[:space:]]*$'; then
    script=$(printf '%s\n' "$cmd" | sed 's/^[[:space:]]*//; s/^sh[[:space:]][[:space:]]*//; s/^"\([^"]*\)".*/\1/; s/^\([^[:space:]]*\).*/\1/')
    case "$script" in
      '${CLAUDE_PLUGIN_ROOT}'/scripts/*|'$CLAUDE_PLUGIN_ROOT'/scripts/*) exit 0 ;;
    esac
    sdir=$(cd "$(dirname "$script")" 2>/dev/null && pwd -P)
    [ -n "$sdir" ] && [ "$sdir" = "$(cd "$SB_PLUGIN/scripts" && pwd -P)" ] && exit 0
  fi
  # The awk pass judges every command and prints each write target (a redirect,
  # or a tee operand) as a T line; the shell then resolves each target.
  verdict=$(printf '%s\n' "$cmd" | sed 's#[0-9]*>[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9]\([^A-Za-z0-9_./~-]\)#\1#g; s#[0-9]*>&[0-9]$##; s#&>[[:space:]]*/dev/null##g' | LC_ALL=C awk '
    BEGIN {
      # Nothing here writes a file. Commands that can, only with certain
      # options or operands (sort, uniq, date, rg), are checked below; less,
      # file, sed, and awk are left off altogether.
      split("ls cat head tail grep egrep fgrep wc stat pwd echo printf true false test [ which type sleep du df ps pgrep kill pkill jobs wait basename dirname realpath readlink cut tr cmp jq md5sum shasum sha1sum sha256sum cksum id whoami uname hostname printenv nl tac rev column", a, " ")
      for (i in a) ok[a[i]] = 1
      split("status log diff show rev-parse ls-files ls-tree blame grep hash-object cat-file describe shortlog show-ref rev-list merge-base check-ignore version whatchanged count-objects name-rev for-each-ref", g, " ")
      for (i in g) gitok[g[i]] = 1
      split("--numeric-sort --reverse --unique --ignore-case --human-numeric-sort --version-sort --general-numeric-sort --month-sort --stable --ignore-leading-blanks --dictionary-order --check --zero-terminated", so, " ")
      for (i in so) sortok[so[i]] = 1
    }
    function bad(why) { print "BAD\t" why; exit }
    {
      line = $0
      while (match(line, /[0-9]*>>?[ \t]*("[^"]*"|\047[^\047]*\047|[^ \t;&|<>()]+)/)) {
        t = substr(line, RSTART, RLENGTH); sub(/^[0-9]*>>?[ \t]*/, "", t); gsub(/["\047]/, "", t)
        print "T\t" t
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
      if (line ~ />/) bad("an output redirect")
      gsub(/["\\\047]/, "", line); n = split(line, seg, /[;&|()`$<{}]/)
      for (s = 1; s <= n; s++) {
        m = split(seg[s], w, /[ \t]+/); i = 1
        while (i <= m && w[i] == "") i++
        if (i > m) continue
        # An environment setting in front of a command can point it at code
        # (GIT_CONFIG_GLOBAL, RIPGREP_CONFIG_PATH), so none is allowed.
        if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) bad("an environment setting (" w[i] ")")
        c = w[i]; sub(/.*\//, "", c)
        if (c == "git") {
          j = i + 1
          while (j <= m && w[j] ~ /^-/) { if (w[j] ~ /^-c/ || w[j] ~ /^--config-env/ || w[j] ~ /^--exec-path/) bad("git " w[j]); if (w[j] == "-C" || w[j] == "--git-dir" || w[j] == "--work-tree") j++; j++ }
          # Options that write a file or run a command: --output, an external
          # diff, and the pager of git grep (-O, --open-files-in-pager), which runs
          # whatever it is given.
          for (k = j + 1; k <= m; k++) if (w[k] ~ /^--output/ || w[k] ~ /^--ext-diff/ || w[k] == "-o" || w[k] ~ /^-O/ || w[k] ~ /^--open-files/ || w[k] ~ /^--textconv/) bad("git " w[j] " " w[k])
          sub_ = w[j]
          # The first word after the subcommand that is not an option.
          for (k = j + 1; k <= m && (w[k] ~ /^-/ || w[k] == ""); k++); nx = (k <= m ? w[k] : "")
          if (sub_ in gitok) continue
          if ((sub_ == "worktree" || sub_ == "stash") && nx == "list") continue
          if (sub_ == "stash" && nx == "show") continue
          if (sub_ == "remote" && (nx == "" || nx == "get-url" || nx == "show")) continue
          if (sub_ == "tag" && nx == "") { for (k = j + 1; k <= m; k++) if (w[k] != "" && w[k] !~ /^(-l|--list|-n[0-9]*)$/) break; if (k > m) continue }
          if (sub_ == "reflog" && (nx == "" || nx == "show")) continue
          if (sub_ == "config") { for (k = j + 1; k <= m; k++) if (w[k] ~ /^(--get|--get-all|--get-regexp|--list|-l)$/) break; if (k <= m) continue }
          if (sub_ == "branch") { for (k = j + 1; k <= m; k++) if (w[k] != "" && w[k] !~ /^(--show-current|--list|-l|-a|--all|-r|--remotes|-v|-vv|--verbose|--contains|--merged|--no-merged)$/) break; if (k > m) continue }
          bad("git " sub_ (nx != "" ? " " nx : ""))
        }
        if (c == "gh") {
          j = i + 1
          while (j <= m && w[j] ~ /^-/) { if (w[j] == "-R" || w[j] == "--repo") j++; j++ }
          g1 = w[j]; g2 = w[j + 1]
          if (g1 == "status" || (g1 == "auth" && g2 == "status")) continue
          if ((g1 == "run" || g1 == "issue" || g1 == "workflow" || g1 == "release") && (g2 == "list" || g2 == "view")) continue
          if (g1 == "pr" && (g2 == "list" || g2 == "view" || g2 == "diff" || g2 == "checks" || g2 == "status")) continue
          if (g1 == "repo" && g2 == "view") continue
          bad("gh " g1 " " g2)
        }
        if (c == "find") {
          for (j = i + 1; j <= m; j++) if (w[j] ~ /^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/) bad("find " w[j])
          continue
        }
        if (c == "sort") {
          # Long options from a list (GNU takes abbreviations, so --out is
          # --output); short clusters without o (output) or T (temp folder).
          for (j = i + 1; j <= m; j++) {
            o = w[j]; sub(/=.*/, "", o)
            if (o ~ /^--/ && !(o in sortok) && o != "--key" && o != "--field-separator") bad("sort " w[j])
            if (o ~ /^-[^-]/ && o ~ /[oT]/) bad("sort " w[j])
          }
          continue
        }
        if (c == "uniq") { o = 0; for (j = i + 1; j <= m; j++) if (w[j] == "-" || (w[j] != "" && w[j] !~ /^-/)) o++; if (o > 1) bad("uniq with an output file"); continue }
        if (c == "date") { for (j = i + 1; j <= m; j++) if (w[j] ~ /^(-s|--set)/) bad("date " w[j]); continue }
        if (c == "rg") { for (j = i + 1; j <= m; j++) if (w[j] ~ /^--pre/) bad("rg " w[j]); continue }
        if (c == "tee") { for (j = i + 1; j <= m; j++) if (w[j] != "" && w[j] !~ /^-/) print "T\t" w[j]; continue }
        if (!(c in ok)) bad(c)
      }
    }')
  bad=$(printf '%s\n' "$verdict" | sed -n 's/^BAD	//p' | head -n 1)
  if [ -z "$bad" ]; then
    # A write target must be a plain absolute path (no glob, no /proc or
    # /dev/fd alias, no dot folder such as ~/.gitconfig, which would turn a
    # read-only git into code) that resolves outside the project, its
    # repository, and the shared .git.
    bad=$(printf '%s\n' "$verdict" | sed -n 's/^T	//p' | while IFS= read -r t; do
      case "$t" in
        /proc/*|/dev/fd/*|*//*|*'*'*|*'?'*|*'['*|*'{'*|*'~'*|*'$'*|*/.*) printf 'a write to %s (only a plain absolute path outside the project may be written)\n' "$t"; break ;;
      esac
      if ! sb_outside_project "$t"; then
        printf 'a write to %s (only a path outside the project may be written)\n' "$t"; break
      fi
    done)
  fi
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
