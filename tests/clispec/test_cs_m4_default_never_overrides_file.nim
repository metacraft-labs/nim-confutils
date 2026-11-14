## test_cs_m4_default_never_overrides_file: a parameter with a ``default``
## that a configuration file sets takes the file's value when the command
## line does not give it. Defaults (and implications) apply only after every
## source is merged, so a default is never mistaken for an explicit value
## that overrides a file.
##
## Falsifying mutation (run by hand): applying
## defaults before the merge makes these cases fail.
##
## Real TOML files in a temporary directory and the real ``Cfg`` program
## (``cs_m4_fixture``); nothing is mocked.

import std/unittest

import ./cs_m4_fixture

suite "test_cs_m4_default_never_overrides_file":
  let s = newScratch()
  let f = s.file("user.toml", header &
    "jobs = 9\ncolor = \"blue\"\n[build]\ntarget = \"lib\"\nopt_level = 1\n")

  test "the file's value, not the default, when the flag is absent":
    let (conf, o) = Cfg.loadWithOrigins(@[], sources([layer("user", f)]))
    check conf.jobs == 9
    check conf.color == blue
    check o.jobs.kind == cokFile
    check o.jobs.winner.line == 2
    check o.jobs.losers.len == 0

  test "in a subcommand too":
    let (conf, o) = Cfg.loadWithOrigins(@["build"],
      sources([layer("user", f)]))
    check conf.build.target == "lib"
    check conf.build.optLevel == 1
    check o.build.target.kind == cokFile

  test "an implication does not override a file either":
    # --release implies optLevel = 3, but the file sets it.
    let (conf, o) = Cfg.loadWithOrigins(@["build", "--release"],
      sources([layer("user", f)]))
    check conf.build.optLevel == 1
    check o.build.optLevel.kind == cokFile

  test "the default still applies when no source gives a value":
    let conf = Cfg.load(@["build"], sources([]))
    check conf.jobs == 4
    check conf.build.target == "all"

  test "the command line still overrides the file":
    let conf = Cfg.load(@["--jobs", "3"], sources([layer("user", f)]))
    check conf.jobs == 3

  s.remove()
