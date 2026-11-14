## The scenario ``test_cs_m9_confutils_over_clispec`` loads: the
## ``cs_m4_fixture`` program read from two TOML layers (the lower one
## binding), the environment and a command line that selects a subcommand,
## with every parameter of the selected commands rendered as one line:
## ``<field> = <value> | <cliDescribe of its origin>``.
##
## The test compares these lines with a golden capture of the same scenario
## loaded through clispec's own layered loader, as it was before
## configuration layers, the environment, merge rules and origins moved to
## confutils, so the move is shown to leave every value and every origin
## (winner, losers and their fates) as it was.

import std/[os, strutils, tables, tempfiles]

import ./cs_m4_fixture

const
  systemToml* = header & "ratio = 1.5\n[build]\ncacheDir = \"/sys/cache\"\n"
    ## The binding layer: it enforces ``ratio`` and ``build.cacheDir``.
  userToml* = header &
    "jobs = 2\nverbose = true\nquiet = 1\ncolor = \"blue\"\n" &
    "tags = [\"a\", \"b\"]\npaths = [\"/u\"]\nlevel = 3\nmode = \"m\"\n" &
    "write_report = \"u.json\"\ntoken = \"file-token\"\nratio = 2.5\n" &
    "[build]\ntarget = \"lib\"\ncacheDir = \"/user/cache\"\n"
  scenarioEnv* = {"CFG_JOBS": "7", "CFG_PATHS": "/e1:/e2", "CFG_LEVEL": "5",
    "CFG_TAGS": "x,y", "COLOR": "red", "CFG_TOKEN": "env-token"}
  scenarioArgv* = ["-qq", "--jobs", "9", "--tags", "z", "--level", "4",
    "--note", "n", "--no-verbose", "build", "--release"]

proc line(name: string; value: auto; origin: CliOrigin; dir: string): string =
  name & " = " & $value & " | " & cliDescribe(origin).replace(dir, "<dir>")

proc scenarioLines*(): seq[string] =
  ## Loads the scenario and renders it.
  let dir = createTempDir("confutils_cs_m9_", "")
  defer: removeDir(dir)
  let system = dir / "system.toml"
  let user = dir / "user.toml"
  writeFile(system, systemToml)
  writeFile(user, userToml)
  let (conf, o) = Cfg.loadWithOrigins(@scenarioArgv,
    CliSources(layers: @[layer("system", system, binding = true),
      layer("user", user)], env: scenarioEnv.toTable,
      format: tomlCliFormat()))
  result.add(line("jobs", conf.jobs, o.jobs, dir))
  result.add(line("verbose", conf.verbose, o.verbose, dir))
  result.add(line("quiet", conf.quiet, o.quiet, dir))
  result.add(line("color", conf.color, o.color, dir))
  result.add(line("tags", conf.tags, o.tags, dir))
  result.add(line("paths", conf.paths, o.paths, dir))
  result.add(line("level", conf.level, o.level, dir))
  result.add(line("mode", conf.mode, o.mode, dir))
  result.add(line("writeReport", conf.writeReport, o.writeReport, dir))
  result.add(line("token", conf.token, o.token, dir))
  result.add(line("note", conf.note, o.note, dir))
  result.add(line("ratio", conf.ratio, o.ratio, dir))
  result.add("command = " & $conf.command & " | " & $o.command)
  result.add(line("build.target", conf.build.target, o.build.target, dir))
  result.add(line("build.optLevel", conf.build.optLevel, o.build.optLevel,
    dir))
  result.add(line("build.release", conf.build.release, o.build.release, dir))
  result.add(line("build.cacheDir", conf.build.cacheDir, o.build.cacheDir,
    dir))

when isMainModule:
  for l in scenarioLines():
    echo l
