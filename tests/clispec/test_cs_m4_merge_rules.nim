## test_cs_m4_merge_rules: each merge rule combines the values of several
## sources as declared.
##
## * ``append`` concatenates every source's list, lowest source first;
## * a combine proc sees every source's value, lowest first, each with its
##   origin, and its result is the value; a combine proc that raises is a
##   ``conflicting sources`` usage error;
## * ``errorOnConflict`` fails naming both sources when they differ, and
##   accepts sources that agree;
## * under ``replace`` a list given several times in one source collects
##   every occurrence, and a higher source's list (an empty one included)
##   replaces a lower one's.
##
## Real TOML files in a temporary directory, an environment table and the
## real ``Cfg`` program (``cs_m4_fixture``); nothing is mocked.

import std/[strutils, unittest]

import ./cs_m4_fixture

suite "test_cs_m4_merge_rules":
  let s = newScratch()

  test "append concatenates lowest source first":
    let a = s.file("a.toml", header & "paths = [\"/sys\"]\n")
    let b = s.file("b.toml", header & "paths = [\"/usr\", \"/home\"]\n")
    let (conf, o) = Cfg.loadWithOrigins(@["--paths", "/cli"],
      sources([layer("system", a), layer("user", b)],
        {"CFG_PATHS": "/env1:/env2"}))
    check conf.paths == @["/sys", "/usr", "/home", "/env1", "/env2", "/cli"]
    check o.paths.kind == cokCli
    check o.paths.values == @["/sys", "/usr", "/home", "/env1:/env2", "/cli"]
    var fates: seq[string] = @[]
    for loser in o.paths.losers:
      fates.add(loser.value & "=" & $loser.fate)
    check fates == @["/sys=combined", "/usr=combined", "/home=combined",
      "/env1:/env2=combined"]

  test "a combine proc sees every candidate, lowest first":
    let a = s.file("lvl.toml", header & "level = 2\n")
    combineCalls.setLen(0)
    let (conf, o) = Cfg.loadWithOrigins(@["--level", "3"],
      sources([layer("user", a)], {"CFG_LEVEL": "5"}))
    check conf.level == 5
    check combineCalls.len == 1
    let seen = combineCalls[0]
    check seen.len == 3
    check seen[0].value == 2
    check seen[0].origin.kind == cokFile
    check seen[0].origin.path == a
    check seen[0].origin.line == 2
    check seen[1].value == 5
    check seen[1].origin.kind == cokEnv
    check seen[1].origin.variable == "CFG_LEVEL"
    check seen[2].value == 3
    check seen[2].origin.kind == cokCli
    check seen[2].origin.argvIndex == 0
    check o.level.kind == cokCli
    check o.level.losers.len == 2
    check o.level.losers[0].fate == cfCombined
    check o.level.losers[1].fate == cfCombined

  test "a combine proc that rejects its input is a conflict":
    combineCalls.setLen(0)
    try:
      discard Cfg.load(@["--level", "-1"], sources([], {"CFG_LEVEL": "5"}))
      check false
    except CliUsageError as e:
      check e.kind == cekConflictingSources
      check "a negative level cannot be combined" in e.msg
      check "'--level'" in e.msg

  test "errorOnConflict fails naming both sources":
    let a = s.file("mode.toml", header & "\nmode = \"fast\"\n")
    try:
      discard Cfg.load(@[], sources([layer("user", a)],
        {"CFG_MODE": "safe"}))
      check false
    except CliUsageError as e:
      check e.kind == cekConflictingSources
      check "'fast' from " & a & ":3 (layer 'user')" in e.msg
      check "'safe' from environment variable CFG_MODE" in e.msg
      check e.spelling == "--mode"
    try:
      discard Cfg.load(@["--mode", "small"], sources([], {"CFG_MODE": "safe"}))
      check false
    except CliUsageError as e:
      check e.kind == cekConflictingSources
      check e.argvIndex == 0
      check "environment variable CFG_MODE" in e.msg
      check "the command line ('--mode', argument 0)" in e.msg

  test "errorOnConflict accepts sources that agree":
    let a = s.file("same.toml", header & "mode = \"fast\"\n")
    let (conf, o) = Cfg.loadWithOrigins(@["--mode=fast"],
      sources([layer("user", a)], {"CFG_MODE": "fast"}))
    check conf.mode == "fast"
    check o.mode.kind == cokCli
    check o.mode.losers.len == 2
    check o.mode.losers[0].fate == cfOverridden

  test "a list repeated within one source collects":
    let (conf, o) = Cfg.loadWithOrigins(@["--tags", "a", "--tags=b,c"],
      sources([]))
    check conf.tags == @["a", "b", "c"]
    check o.tags.values == @["a", "b,c"]
    check o.tags.losers.len == 0

  test "a higher source's list replaces a lower one's":
    let a = s.file("tags.toml", header & "tags = [\"x\", \"y,z\"]\n")
    let fromFile = Cfg.load(@[], sources([layer("user", a)]))
    # A file list's elements are never split on the separator.
    check fromFile.tags == @["x", "y,z"]
    let (conf, o) = Cfg.loadWithOrigins(@["--tags", "a"],
      sources([layer("user", a)], {"CFG_TAGS": "e1,e2"}))
    check conf.tags == @["a"]
    var lost: seq[string] = @[]
    for loser in o.tags.losers:
      lost.add(loser.value)
      check loser.fate == cfOverridden
    check lost == @["x", "y,z", "e1,e2"]

  test "an empty list in a higher layer replaces a lower layer's":
    let a = s.file("t1.toml", header & "tags = [\"x\"]\n")
    let b = s.file("t2.toml", header & "tags = []\n")
    let (conf, o) = Cfg.loadWithOrigins(@[],
      sources([layer("system", a), layer("user", b)]))
    check conf.tags.len == 0
    check o.tags.kind == cokFile
    check o.tags.winner.layer == "user"
    check o.tags.losers.len == 1

  test "a counted flag: occurrences add up within a source, sources replace":
    let a = s.file("q.toml", header & "quiet = 3\n")
    check Cfg.load(@[], sources([layer("user", a)])).quiet == 3
    check Cfg.load(@["-qq"], sources([layer("user", a)])).quiet == 2
    check Cfg.load(@[], sources([layer("user", a)],
      {"CFG_QUIET": "1"})).quiet == 1

  test "a switch from a file, overridden by its negation":
    let a = s.file("v.toml", header & "verbose = true\n")
    check Cfg.load(@[], sources([layer("user", a)])).verbose
    let (conf, o) = Cfg.loadWithOrigins(@["--no-verbose"],
      sources([layer("user", a)]))
    check not conf.verbose
    check o.verbose.winner.spelling == "--no-verbose"
    check o.verbose.losers[0].value == "true"

  s.remove()
