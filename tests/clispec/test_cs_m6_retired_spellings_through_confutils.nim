## test_cs_m6_retired_spellings_through_confutils: clispec's
## ``retired "<spelling>", replacement = "<text>"`` statement (a spelling a
## program no longer accepts, and what replaced it) works unchanged when
## confutils loads the description and merges the command line with a
## configuration file and the environment.
##
## * a retired flag or subcommand word is refused with the error any
##   unknown one gets (``cekUnknownFlag``, ``cekUnknownSubcommand``), whose
##   message, ``retired`` and ``replacement`` name the replacement, with no
##   suggestions; a retired flag is refused in every command nested in the
##   one that declares it;
## * the live spellings beside them load and merge as before;
## * help never lists a retired spelling, and the ``clispec-help/1`` JSON
##   lists them apart, under ``retired``.
##
## A real ``cliConfiguration`` description, a real TOML file and an
## environment table; nothing is mocked.

import std/[json, strutils, unittest]

import ./cs_m4_fixture

cliConfiguration(Rt, "rt", exported = true):
  configSchema "rt.config.v1"
  flag jobs is int, default = 1, env = ["RT_JOBS"]
  retired "--threads", replacement = "--jobs"
  subcmd "switch":
    pos name is string
  subcmd "branch":
    flag fromRole is string, default = "", perSource = [cli = "from"]
    retired "--from-mainlines", replacement = "`--from=mainline`"
    pos path is string
  retired "checkout", replacement = "rt switch <branch>"

const rtHeader = "schema = \"rt.config.v1\"\n"

proc usageErrorOf(argv: seq[string]): ref CliUsageError =
  try:
    discard Rt.load(argv, sources([]))
  except CliUsageError as e:
    return e

suite "test_cs_m6_retired_spellings_through_confutils":
  let s = newScratch()

  test "a retired flag is refused and names its replacement":
    let e = usageErrorOf(@["branch", "--from-mainlines", "x"])
    check not e.isNil
    check e.kind == cekUnknownFlag
    check e.retired == "--from-mainlines"
    check e.replacement == "`--from=mainline`"
    check e.msg == "unknown flag '--from-mainlines' for 'rt branch' " &
      "(a retired spelling; use `--from=mainline`)"
    check e.suggestions.len == 0
    # Declared at the root, refused in a nested command too.
    let nested = usageErrorOf(@["switch", "--threads", "x"])
    check nested.kind == cekUnknownFlag
    check nested.replacement == "--jobs"

  test "a retired subcommand word is refused and names its replacement":
    let e = usageErrorOf(@["checkout", "main"])
    check e.kind == cekUnknownSubcommand
    check e.retired == "checkout"
    check e.replacement == "rt switch <branch>"
    check usageErrorOf(@["chekout"]).suggestions.len == 0

  test "the live spellings still load and merge":
    let f = s.file("rt.toml", rtHeader & "jobs = 3\n")
    let a = Rt.load(@["branch", "--from=mainline", "p"],
      sources([layer("user", f)]))
    check a.branch.fromRole == "mainline"
    check a.branch.path == "p"
    check a.jobs == 3
    let b = Rt.load(@["--jobs=5", "switch", "x"],
      sources([layer("user", f)], {"RT_JOBS": "4"}))
    check b.jobs == 5

  test "help never lists them; the JSON lists them apart":
    for page in [Rt.helpText(), Rt.helpText(@["branch"])]:
      check "checkout" notin page
      check "--threads" notin page
      check "--from-mainlines" notin page
    var spellings: seq[string] = @[]
    for r in parseJson(Rt.helpJson(@["branch"]))["command"]["retired"]:
      spellings.add(r["spelling"].getStr)
    check spellings == @["--from-mainlines", "--threads"]

  s.remove()
