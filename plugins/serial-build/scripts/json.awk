# Flattens one JSON document on stdin into "path<TAB>value" lines, so shell
# scripts can read config and hook input with nothing but awk (jq is not on a
# stock Mac or Linux, and python3 on a fresh Mac is an installer prompt).
#
# Paths join object keys and array indexes with dots: checks.on_edit.0.run.
# Each array also emits "path.#<TAB>length". Strings print without quotes with
# their JSON escapes left in place; json-decode.awk turns them into text.
# Numbers, true, false, and null print as written.
#
# -v only="a b.c": print only those paths (hook input can carry a whole file's
# contents; the hooks need three short fields of it).
# Not JSON: a message on stderr and exit 2.
# Run with LC_ALL=C so lengths and regexes count bytes, not characters.

{ s = s $0 "\n" }

END {
  n = length(s); pos = 1
  if (only != "") only = " " only " "
  ws()
  if (!val("")) bad()
  ws()
  if (pos <= n) bad()
  exit 0
}

function bad() {
  printf "not valid JSON near byte %d\n", pos > "/dev/stderr"
  exit 2
}

function ws(   c) {
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
    else break
  }
}

function join(p, k) { return p == "" ? k : p "." k }

function out(p, v) {
  if (only == "" || index(only, " " p " ") > 0) print p "\t" v
}

function str(   rest) {
  rest = substr(s, pos)
  if (!match(rest, /^"([^"\\]|\\.)*"/)) return 0
  tok = substr(rest, 2, RLENGTH - 2)
  pos += RLENGTH
  return 1
}

function val(p,   c, t) {
  ws()
  if (pos > n) return 0
  c = substr(s, pos, 1)
  if (c == "{") return obj(p)
  if (c == "[") return arr(p)
  if (c == "\"") {
    if (!str()) return 0
    out(p, tok)
    return 1
  }
  t = substr(s, pos, 64)
  if (match(t, /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/) || match(t, /^(true|false|null)/)) {
    out(p, substr(t, 1, RLENGTH))
    pos += RLENGTH
    return 1
  }
  return 0
}

function obj(p,   k, c) {
  pos++
  ws()
  if (substr(s, pos, 1) == "}") { pos++; return 1 }
  while (1) {
    ws()
    if (substr(s, pos, 1) != "\"" || !str()) return 0
    k = tok
    ws()
    if (substr(s, pos, 1) != ":") return 0
    pos++
    if (!val(join(p, k))) return 0
    ws()
    c = substr(s, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "}") { pos++; return 1 }
    return 0
  }
}

function arr(p,   i, c) {
  pos++
  ws()
  i = 0
  if (substr(s, pos, 1) == "]") { pos++; out(join(p, "#"), 0); return 1 }
  while (1) {
    if (!val(join(p, i))) return 0
    i++
    ws()
    c = substr(s, pos, 1)
    if (c == ",") { pos++; continue }
    if (c == "]") { pos++; out(join(p, "#"), i); return 1 }
    return 0
  }
}
