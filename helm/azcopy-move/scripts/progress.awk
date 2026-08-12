# Make azcopy's progress readable in "kubectl logs".
#
# azcopy redraws one status line using a carriage return, which is right for a
# terminal and useless anywhere else. With no TTY the whole run becomes a single
# unbounded line, so `kubectl logs` shows one wall of text and `kubectl logs -f`
# appears to hang. The caller converts \r to \n before this filter, which fixes
# readability but produces an update roughly every two seconds -- about 2500
# lines on an 85 minute run.
#
# This keeps every non-progress line (job ID, warnings, errors, the final
# summary) and thins the progress lines.
#
#   -v INTERVAL=<seconds>     0 or less prints every update
#   -v HAVE_SYSTIME=<0|1>     1 when the awk supports systime()
#
# systime() is a gawk/mawk extension. BSD awk (macOS) and busybox awk lack it,
# and calling it there is a fatal error that would kill the copy pipeline. The
# caller probes for it once and passes the answer in. Without it, this falls
# back to printing every Nth progress line, using azcopy's roughly two-second
# update cadence to approximate the requested interval.

BEGIN {
  last = 0
  seen = 0
  every = int(INTERVAL / 2)          # azcopy updates about every 2 seconds
  if (every < 1) every = 1
}

# Collapse the blank lines that \r\n pairs turn into. azcopy's own blank lines
# carry no information, so losing them costs nothing.
/^[ \t]*$/ { next }

# e.g. "12.3 %, 71 Done, 0 Failed, 774 Pending, 0 Skipped, 845 Total, ..."
/[0-9.]+ %, [0-9]+ Done/ {
  if (INTERVAL + 0 <= 0) { print; fflush(); next }

  if (HAVE_SYSTIME + 0 == 1) {
    now = systime()
    # last = 0 on the first line, so the first update always prints and the run
    # shows something immediately rather than after a silent INTERVAL.
    if (now - last >= INTERVAL + 0) { print; fflush(); last = now }
    next
  }

  # Count-based fallback. seen == 0 prints the first update, as above.
  if (seen % every == 0) { print; fflush() }
  seen++
  next
}

{ print; fflush() }
