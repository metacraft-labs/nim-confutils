## A fixture of test_cs_m9_combine_signature_checked: the line marked
## ``clispec-invalid`` makes this description invalid; the test compiles
## this file and expects the error below, then compiles it again without
## that line and expects success.
## expect: clispec: parameter 'level': merge = `maxOf` is not a combine proc for int; it must be callable as proc (candidates: openArray[CliSourcedValue[int]]): int

import confutils/clispec_config

proc maxOf(values: seq[int]): int =
  ## Takes plain values, not the sourced candidates a combine proc receives.
  for v in values:
    result = max(result, v)

proc strictest(candidates: openArray[CliSourcedValue[int]]): int =
  for c in candidates:
    result = max(result, c.value)

cliConfiguration(Fixture, "fixture"):
  call:
    flag level is int, merge = maxOf  # clispec-invalid
    flag depth is int, merge = strictest
