# dec(v): turns a JSON string body, as json.awk prints it, into text.
# Shared by json-get.awk and render.awk. \uXXXX becomes UTF-8 bytes; a
# surrogate pair (characters outside the Basic Multilingual Plane) becomes "?".

function dec(v,   o, i, c, cp) {
  if (index(v, "\\") == 0) return v
  o = ""
  while ((i = index(v, "\\")) > 0) {
    o = o substr(v, 1, i - 1)
    c = substr(v, i + 1, 1)
    if (c == "u") {
      cp = hex4(substr(v, i + 2, 4))
      o = o utf8(cp)
      v = substr(v, i + 6)
      continue
    }
    if (c == "n") o = o "\n"
    else if (c == "t") o = o "\t"
    else if (c == "r") o = o "\r"
    else if (c != "b" && c != "f") o = o c
    v = substr(v, i + 2)
  }
  return o v
}

function hex4(h,   i, d, x) {
  x = 0
  for (i = 1; i <= 4; i++) {
    d = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (d == 0) return 63
    x = x * 16 + d - 1
  }
  return x
}

function utf8(cp) {
  if (cp == 0) return ""
  if (cp >= 55296 && cp <= 57343) return "?"
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
}
