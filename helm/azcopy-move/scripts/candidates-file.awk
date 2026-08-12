# Read candidate paths from a saved file, for the ad-hoc delete.
#
# Accepts either form the pipeline already produces:
#   delete-list.txt    one relative path per line
#   delete-report.csv  RelativePath,Verdict,Reason,SourceBytes,DestBytes
#
# Emits one relative path per line, ready for decide.awk.
#
# IMPORTANT: every row of a CSV becomes a candidate, including rows whose
# recorded verdict was "keep". That is deliberate. A candidate is not a
# decision -- remove-migrated.sh re-lists the destination and re-compares byte
# counts, so verdicts are recomputed against live state rather than trusted
# from a file that may be hours old. A path that was MISSING when the report
# was written and has since arrived is then correctly picked up.
#
# The first field is written by decide.awk's csv(), which wraps the value in
# double quotes and doubles any embedded quote. A plain split on "," would
# corrupt a path containing a comma, so unquote properly.

function unquote(s,   out, i, c) {
  if (substr(s, 1, 1) != "\"") {
    # Bare line: a path, possibly followed by other CSV fields.
    i = index(s, ",")
    return (i > 0) ? substr(s, 1, i - 1) : s
  }
  out = ""
  i = 2
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c == "\"") {
      # A doubled quote is a literal quote; a lone one ends the field.
      if (substr(s, i + 1, 1) == "\"") { out = out "\""; i += 2; continue }
      return out
    }
    out = out c
    i++
  }
  return out          # unterminated quote: take what there is
}

{ sub(/\r$/, "") }

/^RelativePath,/  { next }        # header
/^[ \t]*$/        { next }

{
  p = unquote($0)
  if (p == "") next
  if (seen[p]++) next             # a path listed twice is still one delete
  print p
}
