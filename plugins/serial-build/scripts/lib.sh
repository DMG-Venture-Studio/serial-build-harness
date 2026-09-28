# Shared by every serial-build script and hook. POSIX sh; needs only awk,
# cksum, find, and git (git only where a script says so).
# The caller sets SB_PLUGIN to the plugin root before sourcing this file.

SB_SCRIPTS="$SB_PLUGIN/scripts"

# Flattens JSON on stdin to "path<TAB>value" lines; $1 optionally limits the paths.
sb_flatten() {
  LC_ALL=C awk -v only="${1:-}" -f "$SB_SCRIPTS/json.awk"
}

# sb_get FLAT PATH: the decoded value, or status 1 when absent.
sb_get() {
  printf '%s\n' "$1" | LC_ALL=C awk -v k="$2" -f "$SB_SCRIPTS/json-decode.awk" -f "$SB_SCRIPTS/json-get.awk"
}

# sb_count FLAT PATH: the length of the array at PATH, 0 when absent.
sb_count() {
  sb_get "$1" "$2.#" || echo 0
}

# The project the session runs in: CLAUDE_PROJECT_DIR in a hook, else the
# working directory (a script run by hand from the project root).
sb_project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s\n' "$CLAUDE_PROJECT_DIR"; else pwd; fi
}

# Loads .claude/serial-build.json into SB_CFG. Status 1 when the project is not
# set up (no file), switched off ("enabled": false), or the file is not JSON
# (SB_CONFIG_ERROR holds the parser's message then). Every hook exits 0 on 1.
sb_load_config() {
  SB_ROOT=$(sb_project_root)
  SB_CONFIG="$SB_ROOT/.claude/serial-build.json"
  SB_CONFIG_ERROR=
  [ -f "$SB_CONFIG" ] || return 1
  if ! SB_CFG=$(sb_flatten < "$SB_CONFIG" 2>&1); then
    SB_CONFIG_ERROR=$SB_CFG
    SB_CFG=
    return 1
  fi
  [ "$(sb_get "$SB_CFG" enabled)" = false ] && return 1
  return 0
}

# Reads hook input JSON from stdin, keeping only the named paths.
sb_read_input() {
  sb_flatten "$1" 2>/dev/null
}

# sb_rel PATH: PATH relative to SB_ROOT; unchanged when outside it.
sb_rel() {
  case "$1" in
    "$SB_ROOT"/*) printf '%s\n' "${1#"$SB_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# sb_rel_project PATH: like sb_rel, but a path inside another git worktree of the
# same repository (the red lane's isolated copy) is made relative to this
# project's place in that worktree, so tests/x.py there reads as tests/x.py.
# Claude Code puts an agent's worktree inside the project, at
# .claude/worktrees/<name>/, so that case is checked before the plain one.
sb_rel_project() {
  case "$1" in
    "$SB_ROOT"/.claude/worktrees/*/*) ;;
    "$SB_ROOT"/*) printf '%s\n' "${1#"$SB_ROOT"/}"; return 0 ;;
    /*) ;;
    *) printf '%s\n' "$1"; return 0 ;;
  esac
  _sb_d=$(dirname "$1")
  while [ ! -d "$_sb_d" ]; do _sb_d=$(dirname "$_sb_d"); done
  _sb_real="$(cd "$_sb_d" && pwd -P)${1#"$_sb_d"}"
  _sb_top=$(git -C "$_sb_d" rev-parse --show-toplevel 2>/dev/null) || { printf '%s\n' "$1"; return 0; }
  _sb_theirs=$(cd "$_sb_d" && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
  _sb_ours=$(cd "$SB_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
  if [ -z "$_sb_ours" ] || [ "$_sb_theirs" != "$_sb_ours" ]; then printf '%s\n' "$1"; return 0; fi
  _sb_prefix=$(git -C "$SB_ROOT" rev-parse --show-prefix 2>/dev/null)
  _sb_base="$_sb_top/${_sb_prefix%/}"
  _sb_base=${_sb_base%/}
  case "$_sb_real" in
    "$_sb_base"/*) printf '%s\n' "${_sb_real#"$_sb_base"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# sb_match PATH PATTERN: shell case-pattern match where * also crosses "/", and
# ** and **/ mean the same as *. So src/** and src/**/*.ts both match src/a/b.ts.
# Only * is a wildcard: [, ], ?, and \ in a pattern match themselves, so a
# path such as app/[id].ts can be listed as it is.
sb_match() {
  _sb_p=$(printf '%s\n' "$2" | sed 's/[][?\\]/\\&/g; s#\*\*/#*#g; s#\*\*#*#g')
  # shellcheck disable=SC2254
  case $1 in $_sb_p) return 0 ;; esac
  return 1
}

# sb_match_any PATH FLAT PREFIX: PATH matches one of the patterns in the array
# at PREFIX. An absent array matches everything.
sb_match_any() {
  _sb_n=$(sb_count "$2" "$3")
  [ "$_sb_n" -eq 0 ] && ! sb_get "$2" "$3.#" >/dev/null && return 0
  _sb_i=0
  while [ "$_sb_i" -lt "$_sb_n" ]; do
    if sb_match "$1" "$(sb_get "$2" "$3.$_sb_i")"; then return 0; fi
    _sb_i=$((_sb_i + 1))
  done
  return 1
}

# A per-user, per-project scratch directory for markers and stamps. It lives in
# the temp directory, never in the project, so nothing needs gitignoring and a
# reboot only costs one re-run of the checks.
sb_state_dir() {
  _sb_key=$(printf '%s' "$SB_ROOT" | cksum | awk '{print $1}')
  _sb_dir="${TMPDIR:-/tmp}"
  _sb_dir="${_sb_dir%/}/serial-build-$(id -u)/$_sb_key"
  mkdir -p "$_sb_dir" 2>/dev/null
  printf '%s\n' "$_sb_dir"
}

# sb_hash: a short checksum of stdin.
sb_hash() {
  cksum | awk '{print $1 "-" $2}'
}

# The inbox directory, relative to the root, or nothing when the inbox is off.
sb_inbox() {
  sb_get "$SB_CFG" inbox 2>/dev/null
}

# sb_inbox_items DIR: each item waiting in the inbox other than its README.
sb_inbox_items() {
  [ -d "$SB_ROOT/$1" ] || return 0
  (cd "$SB_ROOT/$1" && find . -mindepth 1 -maxdepth 1 ! -name README.md ! -name .DS_Store | sed 's|^\./||' | sort)
}

# sb_run_rule CMD FILE: runs CMD with sh from the project root, output to FILE.
sb_run_rule() {
  (cd "$SB_ROOT" && sh -c "$1") > "$2" 2>&1
}

# Files with uncommitted changes under SB_ROOT, one per line, relative to it:
# modified, staged, deleted, and untracked-but-not-ignored. Works from a
# subfolder of a larger repository and in a repository with no commits yet.
# Names with a newline in them are not supported.
# Agents' worktrees (.claude/worktrees/) and Claude Code's per-user permission
# file (.claude/settings.local.json) are never part of the project's changes.
sb_changed_files() {
  (
    cd "$SB_ROOT" || exit 0
    if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
      git -c core.quotePath=false diff --no-renames --name-only -z --relative HEAD -- . "$SB_NOT_WORKTREES" "$SB_NOT_LOCAL"
    else
      git -c core.quotePath=false diff --no-renames --name-only -z --relative --cached -- . "$SB_NOT_WORKTREES" "$SB_NOT_LOCAL"
      git -c core.quotePath=false diff --no-renames --name-only -z --relative -- . "$SB_NOT_WORKTREES" "$SB_NOT_LOCAL"
    fi
    git -c core.quotePath=false ls-files -z --others --exclude-standard -- . "$SB_NOT_WORKTREES" "$SB_NOT_LOCAL"
  ) 2>/dev/null | tr '\0' '\n' | sed '/^$/d' | sb_drop_local | LC_ALL=C sort -u
}
# Drops agent worktrees and the per-user permissions file from a path list; git
# pathspec exclusions miss a folder it has collapsed into one entry.
sb_drop_local() {
  grep -v -e '^\.claude/worktrees$' -e '^\.claude/worktrees/' -e '^\.claude/settings\.local\.json$'
  return 0
}
SB_NOT_WORKTREES=':(exclude).claude/worktrees'
SB_NOT_LOCAL=':(exclude).claude/settings.local.json'

# sb_filter FLAT PREFIX: prints the lines of stdin (paths) that match one of the
# patterns in the array at PREFIX, in one awk pass however many paths there
# are; an absent array passes every path. Same pattern rules as sb_match.
sb_filter() {
  if ! sb_get "$1" "$2.#" >/dev/null; then cat; return 0; fi
  _sb_pats=$(_sb_k=0; _sb_m=$(sb_count "$1" "$2"); while [ "$_sb_k" -lt "$_sb_m" ]; do sb_get "$1" "$2.$_sb_k"; _sb_k=$((_sb_k + 1)); done)
  SB_PATS=$_sb_pats LC_ALL=C awk '
    BEGIN {
      n = split(ENVIRON["SB_PATS"], p, "\n"); re = ""
      for (i = 1; i <= n; i++) {
        if (p[i] == "") continue
        r = ""; s = p[i]; L = length(s)
        for (j = 1; j <= L; j++) {
          c = substr(s, j, 1)
          if (c == "*") {
            k = j
            while (substr(s, j + 1, 1) == "*") j++
            if (j > k && substr(s, j + 1, 1) == "/") j++
            r = r ".*"
          } else if (index("\\.[]()+?{}|^$", c) > 0) r = r "\\" c
          else r = r c
        }
        re = re (re == "" ? "" : "|") r
      }
      re = "^(" re ")$"
    }
    re != "^()$" && $0 ~ re'
}

# sb_sum FILE: a checksum of FILE's content, or "gone".
sb_sum() {
  if [ -f "$1" ]; then cksum < "$1" | awk '{print $1 "-" $2}'; else echo gone; fi
}
