## test_cs_m9_confutils_over_clispec: confutils instantiated over a clispec
## description (``cliConfiguration``) loads a program from a TOML layer, the
## environment and the command line into the same configuration object and
## the same origins that clispec's own layered loader produced before
## configuration layers, the environment, the merge rules and the origin
## object moved from clispec to confutils; and the command line's duties,
## parsing, help and completion, are clispec's: the help a confutils program
## prints is exactly clispec's rendering.
##
## The golden below is the output of ``cs_m9_scenario`` compiled against
## nim-cli-spec ``ab1edb8``, the last revision that carried the layered
## loader itself (``cliProgram`` with ``clispec/toml_source``), with the
## temporary directory written as ``<dir>``.
##
## Negative control: if confutils parsed argv itself, it would render its
## own help. The last case renders the help confutils derives from the same
## configuration type through its type-based machinery (``surfaceFromType``)
## and checks that it differs from clispec's, so the equality checked above
## would fail.
##
## Real TOML files in a temporary directory, the environment as a table,
## the real generated program; nothing is mocked.

import std/[strutils, unittest]

import ./cs_m9_scenario
import ./cs_m4_fixture
import ../../confutils/runtime_surface
from ../../confutils import surfaceFromType

const golden = """
jobs = 9 | 9 from the command line ('--jobs', argument 1); 2 from <dir>/user.toml:2 (layer 'user') overridden; 7 from environment variable CFG_JOBS overridden
verbose = false | false from the command line ('--no-verbose', argument 9); true from <dir>/user.toml:3 (layer 'user') overridden
quiet = 2 | 1, 1 from the command line ('-q', argument 0); 1 from <dir>/user.toml:4 (layer 'user') overridden
color = red | red from environment variable COLOR; blue from <dir>/user.toml:5 (layer 'user') overridden
tags = @["z"] | z from the command line ('--tags', argument 3); a from <dir>/user.toml:6 (layer 'user') overridden; b from <dir>/user.toml:6 (layer 'user') overridden; x,y from environment variable CFG_TAGS overridden
paths = @["/u", "/e1", "/e2"] | /u, /e1:/e2 from environment variable CFG_PATHS; /u from <dir>/user.toml:7 (layer 'user') combined
level = 5 | 3, 5, 4 from the command line ('--level', argument 5); 3 from <dir>/user.toml:8 (layer 'user') combined; 5 from environment variable CFG_LEVEL combined
mode = m | m from <dir>/user.toml:9 (layer 'user')
writeReport = u.json | u.json from <dir>/user.toml:10 (layer 'user')
token = env-token | env-token from environment variable CFG_TOKEN; file-token from <dir>/user.toml:11 (layer 'user') overridden
note = n | n from the command line ('--note', argument 7)
ratio = 1.5 | 1.5 from <dir>/system.toml:2 (layer 'system', binding); 2.5 from <dir>/user.toml:12 (layer 'user') ignored by enforcement
command = build | build
build.target = lib | lib from <dir>/user.toml:14 (layer 'user')
build.optLevel = 3 | 3 from implied by 'release'
build.release = true | <bare> from the command line ('--release', argument 11)
build.cacheDir = /sys/cache | /sys/cache from <dir>/system.toml:4 (layer 'system', binding); /user/cache from <dir>/user.toml:15 (layer 'user') ignored by enforcement
"""

proc helpThroughConfutils(argv: seq[string]): string =
  ## What a confutils program prints for ``argv``: the text of the help
  ## request its layered ``load`` raises.
  let s = newScratch()
  defer: s.remove()
  let user = s.file("user.toml", userToml)
  try:
    discard Cfg.load(argv, sources([layer("user", user)],
      {"CFG_JOBS": "7"}))
  except CliHelpRequest as e:
    return e.text

suite "test_cs_m9_confutils_over_clispec":

  test "the configuration object and origins are those clispec produced":
    let lines = scenarioLines()
    check lines == golden.strip().splitLines()

  test "the same values read field by field":
    let s = newScratch()
    defer: s.remove()
    let system = s.file("system.toml", systemToml)
    let user = s.file("user.toml", userToml)
    let (conf, o) = Cfg.loadWithOrigins(@scenarioArgv,
      sources([layer("system", system, binding = true),
        layer("user", user)], scenarioEnv))
    check conf.jobs == 9
    check o.jobs.winner.kind == cokCli
    check o.jobs.winner.argvIndex == 1
    check o.jobs.winner.spelling == "--jobs"
    check conf.ratio == 1.5
    check o.ratio.kind == cokEnforced
    check o.ratio.losers[0].fate == cfIgnoredByEnforcement
    check conf.paths == @["/u", "/e1", "/e2"]
    check conf.level == 5
    check o.level.losers.len == 2
    check conf.command == CfgCommand.build
    check o.command == CfgCommand.build
    check conf.build.optLevel == 3
    check o.build.optLevel.kind == cokImplied
    # ``load`` gives the same object without the origins.
    let plain = Cfg.load(@scenarioArgv,
      sources([layer("system", system, binding = true),
        layer("user", user)], scenarioEnv))
    check plain.jobs == conf.jobs and plain.paths == conf.paths
    check plain.build.cacheDir == conf.build.cacheDir

  test "help is clispec's, exactly":
    check helpThroughConfutils(@["--help"]) ==
      cliHelpText(Cfg.cliGrammar, 0, "cfg")
    check helpThroughConfutils(@["--help"]) == Cfg.helpText()
    check helpThroughConfutils(@["build", "-h"]) == Cfg.helpText(["build"])
    check helpThroughConfutils(@["--help=json"]) == Cfg.helpJson()
    # Help wins over a broken configuration file, as on clispec's own path.
    let s = newScratch()
    defer: s.remove()
    let broken = s.file("broken.toml", "jobs = [")
    var text = ""
    try:
      discard Cfg.load(@["--help"], sources([layer("user", broken)]))
    except CliHelpRequest as e:
      text = e.text
    check text == Cfg.helpText()

  test "parsing is clispec's: the same errors as without sources":
    var withSources, without: ref CliUsageError
    try:
      discard Cfg.load(@["--jobs"], sources([]))
    except CliUsageError as e:
      withSources = e
    try:
      discard Cfg.load(@["--jobs"])
    except CliUsageError as e:
      without = e
    check withSources != nil and without != nil
    if withSources != nil and without != nil:
      check withSources.kind == cekMissingValue
      check withSources.msg == without.msg
      check withSources.exitCode == without.exitCode

  test "completion is clispec's":
    var answered = ""
    try:
      discard Cfg.load(@["__complete", "fish", "bu"], sources([]))
    except CliCompletionRequest as e:
      answered = e.text
    check answered == Cfg.completionReply(@["fish", "bu"])
    check answered.startsWith("build")

  test "negative control: confutils' own help for the same type differs":
    let own = renderHelpFromSurface(surfaceFromType(Cfg, "cfg"))
    check own.len > 0
    check own != Cfg.helpText()
