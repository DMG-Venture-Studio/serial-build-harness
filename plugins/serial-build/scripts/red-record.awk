# Reads a plan (docs/plan.md, or an old version of it from git) and prints its
# red-lane record as tab-separated rows, one per thing, so every script reads the
# record the same way. Empty fields print as "-".
#
#   TRIED   <bullets on the plan's "Tried to break" list>
#   RUN     <n> <declared attempts> <declared findings> <source> <has attempts list> <fruitless attempts> <findings> <run line>
#   FIND    <run n> <red-slug> <test path@blob> <reproduce command> <the whole bullet, continuation lines joined>
#   DEMOTE  <red-slug> <line>
#   REPIN   <red-slug> <test path@blob> <line>
#   ORPHAN  <findings above the first run line>
#
# A finding bullet may wrap: indented lines after it belong to it.

function field(s, re, pre,   t) {
  if (!match(s, re)) return "-"
  t = substr(s, RSTART, RLENGTH); sub(pre, "", t); sub("`$", "", t)
  return t == "" ? "-" : t
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flush(   slug) {
  if (bullet == "") return
  slug = bullet; sub(/^- /, "", slug); sub(/:.*/, "", slug)
  F[run]++
  printf "FIND\t%d\t%s\t%s\t%s\t%s\n", run, slug, field(bullet, "Test: `[^`]*`", "^Test: `"), field(bullet, "Reproduce: `[^`]*`", "^Reproduce: `"), bullet
  bullet = ""
}

/^Tried to break/ && !inred { tried = 1; next }
tried && /^- / { T++; next }
tried { tried = 0 }

/^## Red[[:space:]]*$/ { inred = 1; next }
/^## / { flush(); inred = 0 }
!inred { next }

bullet != "" && /^[ \t]+[^ \t]/ { bullet = bullet " " trim($0); next }
{ flush() }

/^Red run:/ {
  run++; inatt = 0; line[run] = $0
  N[run] = field($0, "[0-9]+ attempts?", " attempts?$")
  D[run] = field($0, "[0-9]+ findings?", " findings?$")
  S[run] = field($0, "Source: `[^`]*`", "^Source: `")
  next
}
/^Attempts that found nothing:/ { H[run] = 1; inatt = 1; next }
/^- red-/ { inatt = 0; bullet = trim($0); next }
/^- / && inatt { if ($0 !~ /^- none\.?$/) A[run]++; next }
/^Demoted red-/ { s = $2; sub(/:$/, "", s); printf "DEMOTE\t%s\t%s\n", s, $0; next }
/^Re-pinned red-/ { s = $2; sub(/:$/, "", s); printf "REPIN\t%s\t%s\t%s\n", s, field($0, "Test: `[^`]*`", "^Test: `"), $0; next }
NF { inatt = 0 }

END {
  flush()
  printf "TRIED\t%d\n", T
  for (r = 1; r <= run; r++) {
    printf "RUN\t%d\t%s\t%s\t%s\t%d\t%d\t%d\t%s\n", r, (N[r] == "" ? "-" : N[r]), (D[r] == "" ? "-" : D[r]), (S[r] == "" ? "-" : S[r]), H[r] + 0, A[r] + 0, F[r] + 0, line[r]
  }
  if (F[0] > 0) printf "ORPHAN\t%d\n", F[0]
}
