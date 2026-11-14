## test_cs_m4_precedence_and_origins: under ``merge = replace`` the higher
## of two sources wins — a later configuration layer over an earlier one,
## the environment over a file, the command line over both — and the origin
## object names the winner (the file's path and line, the variable, or the
## argv index and spelling) and lists the loser as overridden, with its
## value.
##
## Negative control: a value supplied only by the default reports origin
## ``default`` (not a file, even when files are loaded) and has no losers.
##
## Every case loads the real ``Cfg`` program (``cs_m4_fixture``) from real
## TOML files in a temporary directory and an environment table.

import std/[os, strutils, unittest]

import ./cs_m4_fixture

const kebab = plainCliModel:
  keyStyle kebabCase
  configSchema "k.config.v1"
  flag writeReport is string
  subcmd "debug-dump":
    flag maxDepth is int
    flag raw is string, key = "Raw_Key"

const asDeclared = plainCliModel:
  flag writeReport is string
  subcmd "debug-dump":
    flag maxDepth is int

suite "test_cs_m4_precedence_and_origins":
  let s = newScratch()
  let low = s.file("low.toml", header & "jobs = 1\n\n[build]\ntarget = \"lib\"\n")
  let high = s.file("high.toml", header & "# the user's file\njobs = 2\n")

  test "a later layer replaces an earlier one":
    let (conf, o) = Cfg.loadWithOrigins(@[],
      sources([layer("system", low), layer("user", high)]))
    check conf.jobs == 2
    check o.jobs.kind == cokFile
    check o.jobs.winner.path == high
    check o.jobs.winner.line == 3
    check o.jobs.winner.layer == "user"
    check o.jobs.winner.key == "jobs"
    check o.jobs.values == @["2"]
    check o.jobs.losers.len == 1
    check o.jobs.losers[0].value == "1"
    check o.jobs.losers[0].fate == cfOverridden
    check o.jobs.losers[0].site.kind == cokFile
    check o.jobs.losers[0].site.path == low
    check o.jobs.losers[0].site.line == 2
    check o.jobs.losers[0].site.layer == "system"

  test "the environment replaces a file":
    let (conf, o) = Cfg.loadWithOrigins(@[],
      sources([layer("user", high)], {"CFG_JOBS": "7"}))
    check conf.jobs == 7
    check o.jobs.kind == cokEnv
    check o.jobs.winner.variable == "CFG_JOBS"
    check o.jobs.losers.len == 1
    check o.jobs.losers[0].site.kind == cokFile
    check o.jobs.losers[0].site.path == high
    check o.jobs.losers[0].fate == cfOverridden

  test "the command line replaces the environment":
    let (conf, o) = Cfg.loadWithOrigins(@["-v", "--jobs", "8"],
      sources([], {"CFG_JOBS": "7"}))
    check conf.jobs == 8
    check o.jobs.kind == cokCli
    check o.jobs.winner.argvIndex == 1
    check o.jobs.winner.spelling == "--jobs"
    check o.jobs.losers.len == 1
    check o.jobs.losers[0].value == "7"
    check o.jobs.losers[0].site.kind == cokEnv
    check o.jobs.losers[0].site.variable == "CFG_JOBS"
    check o.jobs.losers[0].fate == cfOverridden

  test "the command line replaces a file":
    let (conf, o) = Cfg.loadWithOrigins(@["--jobs=9"],
      sources([layer("user", high)]))
    check conf.jobs == 9
    check o.jobs.kind == cokCli
    check o.jobs.winner.argvIndex == 0
    check o.jobs.losers.len == 1
    check o.jobs.losers[0].site.path == high

  test "every source at once: losers in the order they were considered":
    let (conf, o) = Cfg.loadWithOrigins(@["--jobs", "8", "--jobs", "9"],
      sources([layer("system", low), layer("user", high)],
        {"CFG_JOBS": "7"}))
    check conf.jobs == 9
    check o.jobs.winner.argvIndex == 2
    var seen: seq[string] = @[]
    for loser in o.jobs.losers:
      seen.add(loser.value & "@" & $loser.site.kind)
      check loser.fate == cfOverridden
    check seen == @["1@file", "2@file", "7@env", "8@cli"]
    check cliDescribe(o.jobs).startsWith("9 from the command line")

  test "the first listed variable that is set supplies the value":
    let (conf, o) = Cfg.loadWithOrigins(@[],
      sources([], {"COLOR": "blue", "UNRELATED": "x"}))
    check conf.color == blue
    check o.color.winner.variable == "COLOR"
    let both = Cfg.loadWithOrigins(@[],
      sources([], {"COLOR": "blue", "CFG_COLOR": "red"}))
    check both.config.color == red
    check both.origins.color.winner.variable == "CFG_COLOR"
    check both.origins.color.losers.len == 0

  test "a subcommand's parameters have origins in the same shape":
    let (conf, o) = Cfg.loadWithOrigins(@["build"],
      sources([layer("system", low)], {"CFG_TARGET": "app"}))
    check conf.command == CfgCommand.build
    check o.command == CfgCommand.build
    check conf.build.target == "app"
    check o.build.target.kind == cokEnv
    check o.build.target.losers[0].site.line == 5
    check o.build.target.losers[0].site.key == "build.target"

  test "an implication is an origin of its own":
    let (conf, o) = Cfg.loadWithOrigins(@["build", "--release"], sources([]))
    check conf.build.optLevel == 3
    check o.build.optLevel.kind == cokImplied
    check o.build.optLevel.winner.impliedBy == "release"
    check o.build.optLevel.values == @["3"]
    check o.build.release.kind == cokCli

  test "negative control: a value only the default supplies":
    # Files are loaded, and they set other keys; jobs is not among them.
    let other = s.file("other.toml", header & "color = \"red\"\n")
    let (conf, o) = Cfg.loadWithOrigins(@["build"],
      sources([layer("user", other)]))
    check conf.jobs == 4
    check o.jobs.kind == cokDefault
    check o.jobs.kind != cokFile
    check o.jobs.losers.len == 0
    check o.jobs.values == @["4"]
    check o.build.target.kind == cokDefault
    check o.build.target.values == @["all"]
    check o.build.target.losers.len == 0
    check o.color.kind == cokFile
    # A parameter nothing supplies, without a default.
    check o.writeReport.kind == cokUnset
    check o.writeReport.losers.len == 0

  test "environment values convert like command-line values":
    let conf = Cfg.load(@[], sources([], {"CFG_VERBOSE": "yes",
      "CFG_QUIET": "2", "CFG_TAGS": "a,b", "CFG_COLOR": "Blue"}))
    check conf.verbose
    check conf.quiet == 2
    check conf.tags == @["a", "b"]
    check conf.color == blue

  test "an invalid environment value names its variable":
    try:
      discard Cfg.load(@[], sources([], {"CFG_JOBS": "many"}))
      check false
    except CliUsageError as e:
      check e.kind == cekInvalidValue
      check e.argvIndex == -1
      check e.source == "environment variable CFG_JOBS"
      check "environment variable CFG_JOBS" in e.msg
      check "expected an integer" in e.msg

  test "an invalid file value names its file and line":
    let bad = s.file("bad.toml", header & "\ncolor = \"purple\"\n")
    try:
      discard Cfg.load(@[], sources([layer("user", bad)]))
      check false
    except CliUsageError as e:
      check e.kind == cekInvalidValue
      check e.source == bad & ":3 (layer 'user')"
      check (bad & ":3") in e.msg
      check "one of: red, green, blue" in e.msg

  test "sources restrict who may supply a parameter":
    expect CliUsageError:
      discard Cfg.load(@["--token", "x"], sources([]))
    let tok = s.file("tok.toml", header & "token = \"from-file\"\n")
    check Cfg.load(@[], sources([layer("user", tok)])).token == "from-file"
    check Cfg.load(@[], sources([layer("user", tok)],
      {"CFG_TOKEN": "from-env"})).token == "from-env"
    check Cfg.load(@["--note", "n"], sources([])).note == "n"
    check "--token" notin Cfg.helpText()

  test "a float key accepts an integer":
    let f = s.file("ratio.toml", header & "ratio = 2\n")
    check Cfg.load(@[], sources([layer("user", f)])).ratio == 2.0

  test "keys are spelt in the declared key style":
    let rep = s.file("report.toml", header &
      "write_report = \"r.json\"\n[build]\nopt_level = 1\ncacheDir = \"c\"\n")
    let conf = Cfg.load(@["build"], sources([layer("user", rep)]))
    check conf.writeReport == "r.json"
    check conf.build.optLevel == 1
    check conf.build.cacheDir == "c"
    var keys: seq[string] = @[]
    for k in Cfg.configSchema.keys:
      keys.add(k.key)
    check "write_report" in keys
    check "build.opt_level" in keys
    check "build.cacheDir" in keys
    check "note" notin keys
    check Cfg.configSchema.id == "cfg.config.v1"
    check "\"clispec-config-schema/1\"" in cliConfigSchemaJson(Cfg.configSchema)

  test "the key style respells derived keys only":
    check kebab.keyStyle == cksKebabCase
    check kebab.configSchema == "k.config.v1"
    check kebab.root.params[0].configKey == "write-report"
    check kebab.commands[0].params[1].configKey == "debug-dump.max-depth"
    check kebab.commands[0].params[2].configKey == "Raw_Key"
    check asDeclared.keyStyle == cksDeclared
    check asDeclared.root.params[0].configKey == "writeReport"
    check asDeclared.commands[0].params[1].configKey == "debug-dump.maxDepth"
    check cliKeySegment("HTTPPort", cksSnakeCase) == "http_port"
    check cliKeySegment("debug-dump", cksSnakeCase) == "debug_dump"
    check cliKeySegment("max_depth", cksKebabCase) == "max-depth"
    check cliKeySegment("jobs", cksSnakeCase) == "jobs"

  test "a missing optional layer is skipped, a missing required one is not":
    let missing = s.dir / "absent.toml"
    check Cfg.load(@[], sources([layer("user", missing)])).jobs == 4
    expect CliConfigError:
      discard Cfg.load(@[], sources([layer("user", missing, required = true)]))

  test "without sources the command line alone still works":
    let (conf, o) = Cfg.loadWithOrigins(@["--jobs", "3"])
    check conf.jobs == 3
    check o.jobs.kind == cokCli
    check Cfg.load(@["--jobs", "3"]).jobs == 3

  s.remove()
