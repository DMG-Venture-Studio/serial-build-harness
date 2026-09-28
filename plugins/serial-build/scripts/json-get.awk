# Prints the decoded value at path k from json.awk output on stdin.
# Exit 1 when the path is absent. Used as: awk -v k=PATH -f json-decode.awk -f json-get.awk

{
  t = index($0, "\t")
  if (t > 0 && substr($0, 1, t - 1) == k) {
    print dec(substr($0, t + 1))
    found = 1
    exit
  }
}

END { exit found ? 0 : 1 }
