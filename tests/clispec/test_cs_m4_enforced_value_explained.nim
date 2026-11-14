## test_cs_m4_enforced_value_explained: a value a binding layer sets wins
## over every higher source — a later layer, the environment and the
## command line — has origin ``enforced`` naming the layer, the file and the
## line, and records each higher source's attempt as ignored by the
## enforcement (and a lower layer's value as overridden), so a program can
## explain the setting.
##
## Falsifying mutation (run by hand): treating the
## binding layer as an ordinary one makes the cases below fail.
##
## Real TOML files in a temporary directory, an environment table and the
## real ``Cfg`` program (``cs_m4_fixture``); nothing is mocked.

import std/[strutils, unittest]

import ./cs_m4_fixture

suite "test_cs_m4_enforced_value_explained":
  let s = newScratch()
  let defaults = s.file("defaults.toml", header & "jobs = 1\n")
  let system = s.file("system.toml", header &
    "# set by the administrator\njobs = 2\nmode = \"safe\"\nlevel = 1\n")
  let user = s.file("user.toml", header & "jobs = 6\n")

  test "a binding layer wins over a later layer, the environment and argv":
    let (conf, o) = Cfg.loadWithOrigins(@["--jobs", "8"],
      sources([layer("defaults", defaults),
               layer("system", system, binding = true),
               layer("user", user)], {"CFG_JOBS": "7"}))
    check conf.jobs == 2
    check o.jobs.kind == cokEnforced
    check o.jobs.winner.layer == "system"
    check o.jobs.winner.path == system
    check o.jobs.winner.line == 3
    check o.jobs.winner.key == "jobs"
    check o.jobs.values == @["2"]
    var lost: seq[string] = @[]
    for loser in o.jobs.losers:
      lost.add(loser.value & "@" & $loser.site.kind & "=" & $loser.fate)
    check lost == @["1@file=overridden", "6@file=ignored by enforcement",
      "7@env=ignored by enforcement", "8@cli=ignored by enforcement"]
    check o.jobs.losers[3].site.argvIndex == 0
    check o.jobs.losers[3].site.spelling == "--jobs"
    let explained = cliDescribe(o.jobs)
    check "(layer 'system', binding)" in explained
    check "ignored by enforcement" in explained

  test "of two binding layers, the lower one enforces":
    let pinned = s.file("pinned.toml", header & "jobs = 9\n")
    let (conf, o) = Cfg.loadWithOrigins(@[],
      sources([layer("system", system, binding = true),
               layer("org", pinned, binding = true)]))
    check conf.jobs == 2
    check o.jobs.winner.layer == "system"
    check o.jobs.losers.len == 1
    check o.jobs.losers[0].fate == cfIgnoredByEnforcement
    # Only the winner is enforced; the other binding layer lost as a file.
    check o.jobs.losers[0].site.kind == cokFile
    check o.jobs.losers[0].site.layer == "org"

  test "an enforced value is not a conflict":
    let (conf, o) = Cfg.loadWithOrigins(@["--mode", "fast"],
      sources([layer("system", system, binding = true)]))
    check conf.mode == "safe"
    check o.mode.kind == cokEnforced
    check o.mode.losers[0].fate == cfIgnoredByEnforcement

  test "an enforced value bypasses the combine proc":
    combineCalls.setLen(0)
    let (conf, o) = Cfg.loadWithOrigins(@["--level", "4"],
      sources([layer("system", system, binding = true)]))
    check conf.level == 1
    check combineCalls.len == 0
    check o.level.kind == cokEnforced
    check o.level.losers[0].fate == cfIgnoredByEnforcement

  test "a binding layer that does not set a key enforces nothing for it":
    let (conf, o) = Cfg.loadWithOrigins(@["--color", "red"],
      sources([layer("system", system, binding = true)]))
    check conf.color == red
    check o.color.kind == cokCli

  test "the same layer, not binding, is overridden as usual":
    let (conf, o) = Cfg.loadWithOrigins(@["--jobs", "8"],
      sources([layer("system", system)]))
    check conf.jobs == 8
    check o.jobs.kind == cokCli
    check o.jobs.losers[0].fate == cfOverridden

  s.remove()
