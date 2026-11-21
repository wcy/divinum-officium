package FixedTime;

# Freezes the clock for regress/compare.pl: every time() returns the same
# moment (DO_FIXED_TIME, epoch seconds; default 2026-10-14 12:00 UTC), so
# that "today", the Ordo's marks and cookies' dates are the same in both
# trees.
BEGIN {
  my $t = $ENV{DO_FIXED_TIME} || 1792022400;
  *CORE::GLOBAL::time = sub () {$t};
}
1;
