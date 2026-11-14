# Prints the compile-time options of `defines_fixture_lib`, one line.

import ./defines_fixture_lib

echo "traces=", fixture_traces, " threads=", fixture_threads,
  " level=", fixture_level, " endings=", fixture_endings,
  " colors=", fixtureColors, " flag=", fixtureFlag
