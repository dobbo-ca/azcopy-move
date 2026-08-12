# Decide, per file, whether the source copy may be deleted.
#
# Reads three files, in this order:
#   SRC   "relpath<TAB>bytes"   from the source listing
#   DST   "relpath<TAB>bytes"   from the destination listing
#   CAND  "relpath[<TAB>desturl]"  candidates from the azcopy job record
#
# Writes:
#   DELLIST    one relative path per line, for "azcopy rm --list-of-files"
#   REPORT     CSV of every candidate with its verdict and reason
#   COUNTFILE  "<ndelete> <nkeep>"
#
# The default verdict is KEEP. A path is deleted only on positive evidence.
#
# -v DESTCHECK=1  the destination listing is real, so require a match there
# -v SIZECHECK=1  compare byte counts between the two listings
# -v RECONCILE=1  also consider source files already matched at the destination
# -v DEST_CONTAINER=<name> the container/share the job is expected to have written to
# -v DEST_ENDPOINT=<url>   the endpoint the job is expected to have written to

function csv(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }

BEGIN { TAB = sprintf("\t") }

FILENAME == SRC  { i = index($0, TAB); if (i > 1) src[substr($0,1,i-1)] = substr($0,i+1); next }
FILENAME == DST  { i = index($0, TAB); if (i > 1) dst[substr($0,1,i-1)] = substr($0,i+1); next }
FILENAME == CAND {
  if ($0 == "") next
  i = index($0, TAB)
  if (i > 1) { p = substr($0,1,i-1); joburl[p] = substr($0,i+1) } else { p = $0 }
  cand[p] = 1
  next
}

END {
  # A file copied in an earlier run but held back by a transient verify failure
  # never appears in a later job record, because the later copy skips it as
  # already present. Without this pass it stays at the source forever.
  if (RECONCILE == "1" && DESTCHECK == "1" && SIZECHECK == "1") {
    added = 0
    for (p in src) {
      if (p in cand) continue
      if ((p in dst) && (src[p] + 0) == (dst[p] + 0)) { cand[p] = 1; added++ }
    }
  }

  print "RelativePath,Verdict,Reason,SourceBytes,DestBytes" > REPORT

  ndel = 0; nkeep = 0
  for (p in cand) {
    verdict = "delete"
    reason  = (DESTCHECK == "1") ? "verified at destination" : "job record only"
    sb = ""; db = ""

    # Free check: did the job write to the container/share we were told about?
    # Anchored at position 1 of the destination root, not a bare substring
    # search -- otherwise a container/share name that also occurs elsewhere in
    # the path (a different container, or the source path itself) falsely
    # passes this check.
    if (DEST_CONTAINER != "" && (p in joburl) && index(joburl[p], DEST_ENDPOINT "/" DEST_CONTAINER "/") != 1) {
      verdict = "keep"; reason = "job wrote elsewhere: " joburl[p]
    }

    if (verdict == "delete" && DESTCHECK == "1") {
      if (!(p in dst)) {
        verdict = "keep"; reason = "MISSING at destination"
      } else {
        db = dst[p]
        if (SIZECHECK == "1") {
          if (!(p in src)) {
            verdict = "keep"; reason = "not at source, already gone?"
          } else {
            sb = src[p]
            if ((sb + 0) != (db + 0)) {
              verdict = "keep"; reason = "SIZE MISMATCH src=" sb " dst=" db
            }
          }
        }
      }
    }

    printf "%s,%s,%s,%s,%s\n", csv(p), csv(verdict), csv(reason), sb, db > REPORT

    if (verdict == "delete") { print p > DELLIST; ndel++ }
    else                     { nkeep++; if (nkeep <= 20) print "  KEEP  " p "  [" reason "]" }
  }

  printf "%d %d %d\n", ndel, nkeep, added > COUNTFILE
}
