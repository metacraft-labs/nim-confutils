## test_cs_m6_after_separator_through_confutils: a clispec positional
## declared ``afterSeparator = true`` (the words after ``--``, as in
## ``env [<assignments>] -- <command>...``) works unchanged when confutils
## loads the description and merges the command line with a configuration
## file and the environment.
##
## * only the words after the first ``--`` fill it, exactly as written (a
##   later ``--`` and words that look like flags included), and a word before
##   ``--`` that no other positional takes is still a usage error;
## * a ``--`` that is a flag's value ends nothing, and the flag's value takes
##   part in the merge like any other command-line value;
## * help, the ``clispec-help/1`` JSON and the model carry the declaration.
##
## A real ``cliConfiguration`` description, a real TOML file and an
## environment table; nothing is mocked.

import std/[json, strutils, unittest]

import ./cs_m4_fixture

cliConfiguration(Ex, "ex", exported = true):
  configSchema "ex.config.v1"
  flag root is string, default = "", env = ["EX_ROOT"]
  pos selector is string, required = false
  pos command is seq[string], required = false, afterSeparator = true

const exHeader = "schema = \"ex.config.v1\"\n"

suite "test_cs_m6_after_separator_through_confutils":
  let s = newScratch()

  test "the words after -- reach the positional exactly as written":
    let f = s.file("ex.toml", exHeader & "root = \"/from-file\"\n")
    let a = Ex.load(@["proj", "--", "ls", "-la", "--", "--root=/x"],
      sources([layer("user", f)]))
    check a.selector == "proj"
    check a.command == @["ls", "-la", "--", "--root=/x"]
    # The flag-looking word after ``--`` is not read as ``--root``.
    check a.root == "/from-file"
    let b = Ex.load(@["--", "ls"], sources([]))
    check b.selector == ""
    check b.command == @["ls"]
    check Ex.load(@["proj"], sources([])).command.len == 0

  test "a word before -- never fills it":
    var refused = false
    try:
      discard Ex.load(@["proj", "extra", "--", "ls"], sources([]))
    except CliUsageError as e:
      refused = e.kind == cekUnexpectedPositional and e.spelling == "extra"
    check refused

  test "a -- that is a flag's value ends nothing and merges as a value":
    let f = s.file("ex2.toml", exHeader & "root = \"/from-file\"\n")
    let (a, o) = Ex.loadWithOrigins(@["--root", "--", "--", "ls"],
      sources([layer("user", f)], {"EX_ROOT": "/from-env"}))
    check a.root == "--"
    check o.root.kind == cokCli
    check a.command == @["ls"]
    let c = Ex.load(@["--root=--", "proj", "--", "x"], sources([]))
    check c.root == "--"
    check c.selector == "proj"
    check c.command == @["x"]

  test "help, the JSON and the model carry it":
    check "Usage: ex [options] [<selector>] [-- <command>...]" in
      Ex.helpText()
    var marked = false
    for p in parseJson(Ex.helpJson())["command"]["parameters"]:
      if p["name"].getStr == "command":
        marked = p["afterSeparator"].getBool
    check marked
    var inModel = false
    for p in Ex.cliModel.root.params:
      if p.name == "command":
        inModel = p.afterSeparator
    check inModel

  s.remove()
