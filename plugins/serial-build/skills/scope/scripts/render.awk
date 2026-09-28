# Replaces each {{key}} in the input with the answer for key. Answers come from
# the json.awk flattening of the answers file (-v answers=FILE); each key with no
# answer is left in place and written once to -v missing=FILE.
# Used as: awk -v answers=A -v missing=M -f json-decode.awk -f render.awk

BEGIN {
  while ((getline line < answers) > 0) {
    t = index(line, "\t")
    if (t > 0) A[substr(line, 1, t - 1)] = dec(substr(line, t + 1))
  }
}

{
  out = ""
  rest = $0
  while ((i = index(rest, "{{")) > 0) {
    j = index(substr(rest, i + 2), "}}")
    if (j == 0) break
    key = substr(rest, i + 2, j - 1)
    out = out substr(rest, 1, i - 1)
    if (key in A) out = out A[key]
    else {
      out = out "{{" key "}}"
      if (!(key in miss)) { miss[key] = 1; print key >> missing }
    }
    rest = substr(rest, i + j + 3)
  }
  print out rest
}
