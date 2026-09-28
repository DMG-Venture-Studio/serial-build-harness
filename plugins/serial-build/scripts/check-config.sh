#!/bin/sh
# Validates a serial-build config and says, in plain words, what each hook will
# do with it. A config the hooks cannot read switches them all off, so this is
# the command to run when a guard seems not to fire.
# Usage: check-config.sh [config file, default: .claude/serial-build.json under the working directory]
# Exit 1 on an error (the hooks would misbehave); warnings alone exit 0.
set -u
SB_PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
. "$SB_PLUGIN/scripts/lib.sh"
file=${1:-$(sb_project_root)/.claude/serial-build.json}
errors=0
err() { printf 'ERROR %s\n' "$1"; errors=$((errors + 1)); }
warn() { printf 'WARN  %s\n' "$1"; }
say() { printf '      %s\n' "$1"; }

[ -f "$file" ] || { err "$file does not exist; every serial-build hook is off for this project (run /serial-build:scope)"; exit 1; }
if ! cfg=$(sb_flatten < "$file" 2>&1); then
  err "$file is not valid JSON ($cfg); every serial-build hook is off until it parses"
  exit 1
fi

known="version enabled owner inbox generated checks red"
for key in $(printf '%s\n' "$cfg" | cut -f 1 | cut -d . -f 1 | sort -u); do
  case " $known " in *" $key "*) ;; *) warn "unknown key \"$key\" is ignored" ;; esac
done

[ "$(sb_get "$cfg" version)" = 1 ] || err "\"version\" must be 1"
if [ "$(sb_get "$cfg" enabled)" = false ]; then
  warn "\"enabled\" is false: every hook is off for this project"
fi
owner=$(sb_get "$cfg" owner.name) || owner=
[ -n "$owner" ] || err "\"owner.name\" is missing; the skills address the product owner by it"
[ -n "$owner" ] && say "product owner: $owner"

inbox=$(sb_get "$cfg" inbox) || inbox=
if [ -n "$inbox" ]; then
  case "$inbox" in /*|*..*) err "\"inbox\" must be a folder inside the project: $inbox" ;; esac
  say "inbox: $inbox/ is listed at session start, and a session that touched it cannot stop while it holds items"
else
  say "inbox: off"
fi

n=$(sb_count "$cfg" generated)
[ "$n" -eq 0 ] && say "generated files: none; nothing is guarded"
i=0
while [ "$i" -lt "$n" ]; do
  p=$(sb_get "$cfg" "generated.$i.path") || { err "generated[$i] has no \"path\""; p=?; }
  r=$(sb_get "$cfg" "generated.$i.regenerate") || { err "generated[$i] has no \"regenerate\" command to name when it refuses an edit"; r=?; }
  say "generated: an edit to $p is refused, naming: $r"
  i=$((i + 1))
done

for event in on_edit on_stop; do
  n=$(sb_count "$cfg" "checks.$event")
  i=0
  while [ "$i" -lt "$n" ]; do
    rule="checks.$event.$i"
    run=$(sb_get "$cfg" "$rule.run") || { err "checks.$event[$i] has no \"run\" command"; run=?; }
    name=$(sb_get "$cfg" "$rule.name") || name="checks.$event[$i]"
    if sb_get "$cfg" "$rule.paths.#" >/dev/null; then
      paths=$(k=0; m=$(sb_count "$cfg" "$rule.paths"); while [ "$k" -lt "$m" ]; do printf '%s ' "$(sb_get "$cfg" "$rule.paths.$k")"; k=$((k + 1)); done)
      [ -n "$paths" ] || warn "checks.$event[$i] ($name) has an empty \"paths\" list, so it never runs"
    else
      paths="(every file)"
    fi
    if [ "$event" = on_edit ]; then
      say "after each edit to $paths: $name runs \`$run\`; a failure is fed back to the session"
    else
      say "at stop, when $paths has uncommitted changes not yet passed: $name runs \`$run\`; a failure keeps the session working"
    fi
    i=$((i + 1))
  done
done
[ "$(sb_count "$cfg" checks.on_edit)" -eq 0 ] && [ "$(sb_count "$cfg" checks.on_stop)" -eq 0 ] && warn "no checks configured: nothing lints on edit or tests at stop"

n=$(sb_count "$cfg" red.test_paths)
if [ "$n" -eq 0 ]; then
  warn "\"red.test_paths\" is missing: /serial-build:red refuses to run, and no gate can hand off"
else
  paths=$(k=0; while [ "$k" -lt "$n" ]; do printf '%s ' "$(sb_get "$cfg" "red.test_paths.$k")"; k=$((k + 1)); done)
  say "red lane: the red-breaker agent may write only $paths"
fi

[ "$errors" -eq 0 ] && printf 'OK    %s\n' "$file"
[ "$errors" -eq 0 ]
