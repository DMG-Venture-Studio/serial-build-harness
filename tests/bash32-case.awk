# Flags a case pattern without a leading "(" inside an open $( ... ): track,
# outside single and double quotes, a stack of open parens, marking which are $(.
{
  line = $0; n = length(line)
  if (!sq && line ~ /^[ \t]*#/) next
  if (incase && !sq && !dq) {
    if (line ~ /^[ \t]*esac/) incase = 0
    else if (line ~ /^[ \t]*[^ \t(#]/ && line ~ /\)/ && subs > 0) { print f ":" FNR; incase = 0 }
  }
  if (!sq && !dq && subs > 0 && line ~ /^[ \t]*case .* in[ \t]*$/) incase = 1
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (sq) { if (c == "'") sq = 0; continue }
    if (c == "\\") { i++; continue }
    if (c == "\"") { dq = !dq; continue }
    if (dq && c != "$" && c != ")") continue
    if (c == "'" && !dq) { sq = 1; continue }
    if (c == "#" && !dq && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) break
    if (c == "$" && substr(line, i + 1, 1) == "(") { st[++d] = 1; subs++; i++; continue }
    if (c == "(" && !dq) { st[++d] = 0; continue }
    if (c == ")" && d > 0 && !(incase && !st[d])) { if (st[d]) subs--; d--; continue }
  }
}
