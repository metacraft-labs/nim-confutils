## test_cs_m6_argv_of_origins: the command-line part of a configuration
## loaded over every source, written back as argv words (``argvOf`` over an
## origin object, clispec's ``cliArgvOf``).
##
## What it pins:
##
## * the origin of a value records the command line's occurrences that are
##   part of it (``CliOrigin.commandLine``), and none when another source,
##   a default or an implication decided it, or an enforced value ignored
##   the command line;
## * ``argvOf`` writes only those: a value an environment variable, a file,
##   a default or an implication gave is never in the words, and under
##   ``merge = append`` only the command line's part of the value is;
## * the property, over a table and a few thousand random command lines
##   loaded with one set of files and variables: loading the words with the
##   same sources gives the same configuration, every field decided by the
##   same kind of source, and ``argvOf`` of that is the same words;
## * ``argvOf`` over a subcommand's origin object, and over the flags one
##   command shares with another (a ``test`` that runs a ``build`` with the
##   build flags it was given), which the other command reads back.
##
## The fixture is ``cs_m4_fixture``'s ``Cfg`` (every merge rule, binding
## layers, implications) plus a two-command description; real TOML files
## and an environment table; nothing is mocked.

import std/[random, strutils, unittest]

import ./cs_m4_fixture

cliConfiguration(Pair, "pair", exported = true):
  configSchema "pair.config.v1"
  subcmd "build":
    flag jobs is int, default = 4, env = ["PAIR_JOBS"]
    flag variant is seq[string]
    boolFlag release is bool, alsoSets = [variant = "buildType=release"]
    boolFlag dryRun is bool
    pos selectors is seq[string], required = false
    pos actionArgs is seq[string], required = false, afterSeparator = true
  subcmd "test":
    flag shard is string, default = ""
    flag jobs is int, default = 4, env = ["PAIR_JOBS"]
    flag variant is seq[string]
    boolFlag release is bool, alsoSets = [variant = "buildType=release"]
    boolFlag dryRun is bool
    pos selectors is seq[string], required = false
    pos actionArgs is seq[string], required = false, afterSeparator = true


proc originKinds[T: object](o: T; into: var seq[CliOriginKind]) =
  ## The winning source's kind of every field of an origin object, its
  ## selected subcommand's included.
  for name, value in fieldPairs(o):
    when value is CliOrigin:
      into.add(value.winner.kind)
    elif value is object:
      originKinds(value, into)

proc kindsOf[T: object](o: T): seq[CliOriginKind] =
  originKinds(o, result)

template checkSame(argv: seq[string]; src: CliSources) =
  ## The property for one command line ``Cfg`` accepts.
  block:
    let (c1, o1) = Cfg.loadWithOrigins(argv, src)
    let words = argvOf(o1)
    checkpoint("argv:  " & $argv)
    checkpoint("words: " & $words)
    let (c2, o2) = Cfg.loadWithOrigins(words, src)
    check $c2 == $c1
    check kindsOf(o2) == kindsOf(o1)
    check argvOf(o2) == words

const tricky = ["", "-", "--", "-x", "a,b", "x:y", "1", "7", "red", "blue",
  "build", "true", "false"]

proc randomArgv(rng: var Rand; g: CliGrammar): seq[string] =
  ## A command line over ``Cfg``'s grammar: the root's flags, maybe
  ## ``build`` and its flags, in the spellings each flag has.
  var commands = @[0]
  if rng.rand(1) == 0:
    commands.add(cliHelpCommand(g, ["build"], "cfg"))
  for k, command in commands:
    if k > 0:
      result.add("build")
    var flags: seq[int] = @[]
    for id in g.commands[command].params:
      let p = g.params[id]
      if p.kind == cpkFlag and csCli in p.sources:
        flags.add(id)
    for _ in 0 ..< rng.rand(5):
      let p = g.params[rng.sample(flags)]
      let spelling = rng.sample(cliFlagSpellings(p))
      if p.isSwitch or p.counted:
        if p.negatable and rng.rand(3) == 0:
          result.add("--no-" & cliLongName(p))
        else:
          result.add(spelling)
      else:
        let value = if p.nimType == "int": $rng.rand(0 .. 9)
                    elif p.choices.len > 0: rng.sample(p.choices)
                    else: rng.sample(tricky)
        if spelling.startsWith("--") and rng.rand(1) == 0:
          result.add(spelling & "=" & value)
        else:
          result.add([spelling, value])

suite "test_cs_m6_argv_of_origins":
  let s = newScratch()
  let file = s.file("user.toml", header &
    "jobs = 2\npaths = [\"/f\"]\nlevel = 3\ntags = [\"t\"]\n" &
    "[build]\ntarget = \"lib\"\n")
  let src = sources([layer("user", file)], {"CFG_COLOR": "blue",
    "CFG_PATHS": "/e1:/e2", "CFG_LEVEL": "1", "CFG_TOKEN": "secret",
    "CFG_QUIET": "2"})

  test "only the command line's occurrences are recorded and written":
    let (c, o) = Cfg.loadWithOrigins(@["-v", "--paths=/c", "--level", "5",
      "build", "--release"], src)
    check c.paths == @["/f", "/e1", "/e2", "/c"]
    check o.paths.commandLine.len == 1
    check o.paths.commandLine[0].text == "/c"
    check o.jobs.commandLine.len == 0      # the file's
    check o.color.commandLine.len == 0     # the environment's
    check o.token.commandLine.len == 0
    check o.build.optLevel.commandLine.len == 0   # implied
    check o.build.target.commandLine.len == 0     # the file's
    check c.build.optLevel == 3
    check argvOf(o) == @["build", "--verbose", "--paths=/c", "--level=5",
      "--release"]
    checkSame(@["-v", "--paths=/c", "--level", "5", "build", "--release"],
      src)

  test "a value an enforced layer decided is not the command line's":
    let pinned = s.file("pinned.toml", header & "jobs = 1\n")
    let bound = sources([layer("system", pinned, binding = true),
      layer("user", file)])
    let (c, o) = Cfg.loadWithOrigins(@["--jobs", "8", "-q"], bound)
    check c.jobs == 1
    check o.jobs.kind == cokEnforced
    check o.jobs.commandLine.len == 0
    check argvOf(o) == @["--quiet"]
    checkSame(@["--jobs", "8", "-q"], bound)

  test "a subcommand's origin object, and a selection":
    let (_, o) = Cfg.loadWithOrigins(@["-q", "build", "--target=x",
      "--release", "--cacheDir=/c"], src)
    check argvOf(o.build) == @["--target=x", "--release", "--cacheDir=/c"]
    check argvOf(o, only = ["target"]) == @["build", "--target=x"]
    check argvOf(o, only = ["target"], commandWords = false) ==
      @["--target=x"]
    expect ValueError:
      discard argvOf(o, only = ["nosuch"])

  test "the flags one command shares with another":
    let (t, o) = Pair.loadWithOrigins(@["test", "--shard=1/2", "--release",
      "--variant=a=1", "--dryRun", "sel", "--", "-x"],
      CliSources(env: {"PAIR_JOBS": "6"}.toTable))
    let g = Pair.cliGrammar()
    var buildFlags: seq[string] = @[]
    for id in g.commands[cliHelpCommand(g, ["build"], "pair")].params:
      if g.params[id].kind == cpkFlag:
        buildFlags.add(g.params[id].name)
    let words = argvOf(o.test, only = buildFlags)
    # The variable's value is not written: the build reads it itself.
    check words == @["--release", "--variant=a=1", "--dryRun"]
    let (b, bo) = Pair.loadWithOrigins(@["build"] & words &
      t.test.selectors & @["--"] & t.test.actionArgs,
      CliSources(env: {"PAIR_JOBS": "6"}.toTable))
    check b.build.jobs == 6
    check bo.build.jobs.kind == cokEnv
    check b.build.variant == t.test.variant
    check bo.build.variant.kind == cokCli
    check b.build.release and b.build.dryRun
    check b.build.actionArgs == @["-x"]
    # A value a flag's ``alsoSets`` gave is part of the origin's command
    # line, so a switch given twice is written twice, in place.
    let (t2, o2) = Pair.loadWithOrigins(@["test", "--release",
      "--variant=a=1", "--release"], CliSources())
    check t2.test.variant == @["buildType=release", "a=1",
      "buildType=release"]
    check o2.test.variant.commandLine.len == 3
    check o2.test.variant.commandLine[0].setBy == "release"
    let again = argvOf(o2.test, only = buildFlags)
    check again == @["--release", "--variant=a=1", "--release"]
    check Pair.load(@["build"] & again, CliSources()).build.variant ==
      t2.test.variant

  test "a table of command lines":
    for argv in [@[], @["build"], @["--no-verbose", "-qq", "--tags=a,b",
                 "--tags", "c"], @["--mode", "-", "--write-report", "--"],
                 @["--writeReport", "", "--note=x", "--ratio=1.5"],
                 @["--dry", "--color=red"]]:
      var accepted = true
      try:
        discard Cfg.load(argv, src)
      except CliUsageError, CliHelpRequest, CliConfigError:
        accepted = false
      if accepted:
        checkSame(argv, src)

  test "random command lines":
    var rng = initRand(20261117)
    let g = Cfg.cliGrammar()
    var acceptedCount = 0
    for _ in 0 ..< 1500:
      let argv = randomArgv(rng, g)
      var accepted = true
      try:
        discard Cfg.load(argv, src)
      except CliUsageError, CliHelpRequest, CliConfigError:
        accepted = false
      if accepted:
        inc acceptedCount
        checkSame(argv, src)
    check acceptedCount >= 300

  s.remove()
