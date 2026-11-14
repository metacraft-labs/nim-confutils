## test_cs_m10_compat_rules_through_merge: clispec's opt-in compatibility
## rules work when confutils merges the command line with configuration
## files and the environment.
##
## * ``alsoSets``: a flag's occurrence is a command-line candidate of the
##   other parameter at the flag's position, so confutils' merge orders it
##   with that parameter's own occurrences and records it in the origin,
##   and the command line still outranks a file and the environment;
## * ``acceptsNextWord`` and ``valueErrorsBeforeHelp`` need the value check
##   clispec generates, which confutils' ``load`` passes to the parser;
## * ``switchesRefuseFalse`` and ``flagMatching`` are the parser's, and
##   reach confutils unchanged.
##
## A real ``cliConfiguration`` description, real TOML files and an
## environment table; nothing is mocked.

import std/[options, unittest]

import ./cs_m4_fixture

cliConfiguration(Cm, "cm", exported = true):
  configSchema "cm.config.v1"
  flagMatching ignoreStyle
  parsing valueErrorsBeforeHelp, switchesRefuseFalse
  flag attach is string, values = ["early", "late", "lazy"],
    env = ["CM_ATTACH"], alsoSets = [attachGiven = "true"]
  boolFlag attachGiven is bool, sources = {}
  boolFlag legacy is bool, alsoSets = [attach = "early"]
  flag diag is seq[string], env = ["CM_DIAG"]
  boolFlag diagStrict is bool, alsoSets = [diag = "strict"]
  flag level is Option[int], optionalValue = some(1), acceptsNextWord = true
  pos rest is seq[string], required = false

const cmHeader = "schema = \"cm.config.v1\"\n"

suite "test_cs_m10_compat_rules_through_merge":
  let s = newScratch()

  test "alsoSets candidates merge in command-line order, over a file":
    let f = s.file("cm.toml", cmHeader & "attach = \"lazy\"\n")
    let (a, oa) = Cm.loadWithOrigins(@["--attach=late", "--legacy"],
      sources([layer("user", f)], {"CM_ATTACH": "late"}))
    check a.attach == "early"
    check a.attachGiven
    check oa.attach.kind == cokCli
    check oa.attach.winner.argvIndex == 1
    check oa.attach.winner.spelling == "--legacy"
    check oa.attach.values == @["early"]
    check oa.attach.losers.len == 3
    check oa.attach.losers[0].value == "lazy"
    check oa.attach.losers[1].value == "late"
    check oa.attach.losers[2].value == "late"
    check oa.attach.losers[2].fate == cfOverridden
    let (b, ob) = Cm.loadWithOrigins(@["--legacy", "--attach", "late"],
      sources([layer("user", f)]))
    check b.attach == "late"
    check ob.attach.winner.argvIndex == 1
    # Without a command-line occurrence the file still decides.
    let c = Cm.load(@[], sources([layer("user", f)]))
    check c.attach == "lazy"
    check not c.attachGiven

  test "alsoSets into a list collects in command-line order":
    let conf = Cm.load(@["--diag=a", "--diagStrict", "--diag=b"],
      sources([], {"CM_DIAG": "env"}))
    check conf.diag == @["a", "strict", "b"]
    check Cm.load(@[], sources([], {"CM_DIAG": "env"})).diag == @["env"]

  test "acceptsNextWord takes a valid next word through confutils' load":
    check Cm.load(@["--level", "5"], sources([])).level == some(5)
    let r = Cm.load(@["--level", "x"], sources([]))
    check r.level == some(1)
    check r.rest == @["x"]

  test "a rejected value before the help request wins over help":
    try:
      discard Cm.load(@["--attach=bogus", "-h"], sources([]))
      check false
    except CliUsageError as e:
      check e.kind == cekInvalidValue
      check e.value == "bogus"
    except CliHelpRequest:
      check false
    expect CliHelpRequest:
      discard Cm.load(@["-h", "--attach=bogus"], sources([]))

  test "a refused false switch and case-insensitive spellings":
    try:
      discard Cm.load(@["--legacy=off"], sources([]))
      check false
    except CliUsageError as e:
      check e.kind == cekSwitchFalseValue
      check e.spelling == "--legacy"
    check Cm.load(@["--ATTACH", "late"], sources([])).attach == "late"

  s.remove()
