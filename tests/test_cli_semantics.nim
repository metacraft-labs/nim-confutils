# nim-confutils
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Command-line semantics a LIBRARY caller relies on: `load(...,
## quitOnFailure = false)` must report every error as a populated
## `ConfigurationError` (never print-and-quit, never an empty message), a
## value-taking option must never lose its value silently, and help must be
## renderable without quitting.  Each suite pins one of those changes; the
## inputs are real command lines through the real `load`, with no mocks.

import
  std/[options, os, strutils],
  unittest2,
  ../confutils

type
  Mode = distinct string

func parseCmdArg(T: type Mode, s: string): T {.raises: [ValueError].} =
  if s notin ["fast", "slow"]:
    raise newException(ValueError, "mode must be fast or slow, got '" & s & "'")
  Mode(s)

func completeCmdArg(T: type Mode, val: string): seq[string] = @[]

func `==`(a, b: Mode): bool {.borrow.}

const SharedDesc = "Described by a named constant"

type
  Conf = object
    output {.
      desc: "Where to write"
      valueName: "path"
      abbr: "o"
      name: "output" }: Option[string]

    count {.
      desc: "How many"
      name: "count" }: Option[int]

    verbose {.
      desc: "Talk more"
      abbr: "v"
      name: "verbose" }: bool

    mode {.
      desc: "Optional-value option"
      longDesc: "bare is fast\nslow is the other one"
      implicitValue: "fast"
      valueName: "fast|slow"
      name: "mode" }: Option[Mode]

    tags {.
      desc: SharedDesc
      name: "tag" }: seq[string]

    tagAlpha {.
      desc: "Same as --tag alpha"
      alsoSets("tags", "alpha")
      name: "tag-alpha" }: bool

    sel {.
      desc: "Selector"
      alsoSets("explicitSelect", "true")
      name: "select" }: Option[string]

    selFast {.
      desc: "Deprecated alias of --select=fast"
      alsoSets("sel", "fast")
      abbr: "sf"
      name: "select-fast" }: bool

    explicitSelect {.ignore.}: bool

proc loadConf(args: seq[string], prefix = ""): Conf {.raises: [ConfigurationError].} =
  Conf.load(cmdLine = args, quitOnFailure = false, envVarsPrefix = prefix)

proc errorOf(args: seq[string]): ref ConfigurationError =
  try:
    discard loadConf(args)
  except ConfigurationError as e:
    return e
  nil

suite "ConfigurationError is populated when not quitting":
  test "an unknown option names itself":
    let e = errorOf(@["--nope"])
    check e != nil
    check e.kind == cekUnknownOption
    check e.option == "--nope"
    check e.value == ""
    check errorOf(@["--nope=1"]).value == "1"
    check e.msg.len > 0 and "nope" in e.msg

  test "an invalid value carries the parser's reason":
    let e = errorOf(@["--count=many"])
    check e != nil
    check e.kind == cekInvalidValue
    check e.option == "--count"
    check e.optionName == "count"
    check e.value == "many"
    check e.detail.len > 0
    check "count=many" in e.msg

    let m = errorOf(@["--mode=medium"])
    check m != nil and m.kind == cekInvalidValue
    check m.detail == "mode must be fast or slow, got 'medium'"

  test "a stray positional argument is reported":
    let e = errorOf(@["stray"])
    check e != nil
    check e.kind == cekUnexpectedArgument
    check e.option == "stray"

suite "a value-taking option never loses its value":
  test "--name value and --name=value agree":
    check loadConf(@["--output", "a"]).output == some("a")
    check loadConf(@["--output=a"]).output == some("a")
    check loadConf(@["--output:a"]).output == some("a")
    check loadConf(@["--count", "3"]).count == some(3)
    check loadConf(@["--count=3"]).count == some(3)

  test "short forms":
    check loadConf(@["-o", "a"]).output == some("a")
    check loadConf(@["-o=a"]).output == some("a")
    check loadConf(@["-oa"]).output == some("a")
    let c = loadConf(@["-vo", "a"])
    check c.verbose and c.output == some("a")

  test "the value is taken verbatim, even when it begins with '-'":
    check loadConf(@["--output", "-"]).output == some("-")
    check loadConf(@["--output", "--verbose"]).output == some("--verbose")
    check not loadConf(@["--output", "--verbose"]).verbose
    check loadConf(@["--output", "--help"]).output == some("--help")
    check loadConf(@["--count", "-5"]).count == some(-5)

  test "an option followed by another option is no longer dropped":
    # Formerly `--output` became "pending" and the next OPTION was processed
    # as an option, leaving `output` unset without a word.
    let c = loadConf(@["--output", "x", "--verbose"])
    check c.output == some("x") and c.verbose

  test "a value-taking option last on the command line is an error":
    let e = errorOf(@["--verbose", "--output"])
    check e != nil
    check e.kind == cekMissingValue
    check e.option == "--output"
    check e.optionName == "output"
    check "--output" in e.msg and "<path>" in e.msg
    let s = errorOf(@["-o"])
    check s != nil and s.kind == cekMissingValue and s.option == "-o"

  test "an explicit empty value is a value":
    check loadConf(@["--output="]).output == some("")

  test "a switch takes no value from the next token":
    let e = errorOf(@["--verbose", "false"])
    check e != nil and e.kind == cekUnexpectedArgument
    check not loadConf(@["--verbose=false"]).verbose

suite "environment lookup":
  test "an empty prefix turns it off":
    putEnv("_OUTPUT", "from-env")
    putEnv("CFTEST_OUTPUT", "from-env")
    defer:
      delEnv("_OUTPUT")
      delEnv("CFTEST_OUTPUT")
    check loadConf(@[]).output.isNone
    # ...and a non-empty one still reads it (the positive control).
    check loadConf(@[], "cftest").output == some("from-env")

suite "help does not quit a library caller":
  test "--help and -h raise cekHelpRequested":
    for h in ["--help", "-h", "--h"]:
      let e = errorOf(@["--verbose", h, "--nope"])
      check e != nil
      check e.kind == cekHelpRequested
      check e.option == h

  test "an earlier error still wins over a later --help":
    let e = errorOf(@["--nope", "--help"])
    check e != nil and e.kind == cekUnknownOption

suite "implicitValue: an option whose value is optional":
  test "bare, last on the line":
    check loadConf(@["--mode"]).mode == some(Mode("fast"))

  test "bare, before another option":
    let c = loadConf(@["--mode", "--verbose"])
    check c.mode == some(Mode("fast")) and c.verbose

  test "followed by a valid value, it takes it":
    check loadConf(@["--mode", "slow"]).mode == some(Mode("slow"))
    check loadConf(@["--mode=slow"]).mode == some(Mode("slow"))

  test "followed by something that is not a value, it does not":
    let e = errorOf(@["--mode", "medium"])
    check e != nil
    check e.kind == cekUnexpectedArgument and e.option == "medium"

  test "an explicit invalid value is still an error":
    let e = errorOf(@["--mode=medium"])
    check e != nil and e.kind == cekInvalidValue

suite "alsoSets: one option writing a second field, in order":
  test "a seq target accumulates in command-line order":
    check loadConf(@["--tag", "x", "--tag-alpha", "--tag=y"]).tags ==
      @["x", "alpha", "y"]
    check loadConf(@["--tag-alpha", "--tag", "x"]).tags == @["alpha", "x"]

  test "a scalar target takes whichever spelling came last":
    check loadConf(@["--select", "a", "--select-fast"]).sel == some("fast")
    check loadConf(@["--select-fast", "--select", "a"]).sel == some("a")
    let c = loadConf(@["--select-fast"])
    check c.selFast and c.sel == some("fast")

  test "a switch set to false does not fire it":
    let c = loadConf(@["--select-fast=false"])
    check not c.selFast and c.sel.isNone

  test "a multi-character abbreviation is a long spelling":
    let c = loadConf(@["--sf"])
    check c.selFast and c.sel == some("fast")

suite "help rendered from the declarative table":
  const surface = surfaceFromType(Conf)

  test "the surface carries every visible option, in order":
    var names: seq[string]
    for f in surface.globalFlags: names.add f.name
    check names == @["output", "count", "verbose", "mode", "tag", "tag-alpha",
                     "select", "select-fast"]

  test "a named constant reaches the description":
    let i = surface.globalFlags.findFlagIdx("tag")
    check surface.globalFlags[i].description == SharedDesc

  test "value shape and spellings":
    let fl = surface.globalFlags
    check fl[fl.findFlagIdx("output")].takesValue
    check fl[fl.findFlagIdx("output")].short == 'o'
    check not fl[fl.findFlagIdx("verbose")].takesValue
    check fl[fl.findFlagIdx("mode")].valueOptional
    let sf = fl[fl.findFlagIdx("select-fast")]
    check sf.short == '\0' and sf.aliases == @["sf"]

  test "renderOptionsTable":
    let text = renderOptionsTable(surface.globalFlags, indent = 2,
                                  column = 30, width = 60)
    check "  -o, --output <path>         Where to write\n" in text
    check "  --mode[=<fast|slow>]        Optional-value option\n" in text
    check "\n                              bare is fast\n" in text
    check "\n                              slow is the other one\n" in text
    check "  --select-fast, --sf         Deprecated alias of" in text
    for line in text.splitLines():
      check line.len <= 60

  test "a switch column too wide for its space wraps":
    let flags = @[RuntimeFlag(name: "a-very-long-option-name-indeed",
                              takesValue: true, valueName: "thing",
                              description: "Desc")]
    check renderOptionsTable(flags, column = 20) ==
      "  --a-very-long-option-name-indeed <thing>\n" &
      "                    Desc\n"

suite "alsoSets into an ignored field":
  test "records the fact without being an option":
    check loadConf(@["--select", "a"]).explicitSelect
    check not loadConf(@["--select-fast"]).explicitSelect
    let e = errorOf(@["--explicitSelect"])
    check e != nil and e.kind == cekUnknownOption

suite "an empty key names no option":
  # `findOpt` compared the empty key of a lone `-` (or `--=x`) with the empty
  # `abbr` of every option declared without one, so `-` was read as `--count`,
  # the first such option here.
  test "a lone '-' is an unknown option, not the first option":
    let e = errorOf(@["-"])
    check e != nil and e.kind == cekUnknownOption and e.option == "-"
    let v = errorOf(@["-o", "a", "-"])
    check v != nil and v.kind == cekUnknownOption

  test "'--=value' is an unknown option":
    let e = errorOf(@["--=3"])
    check e != nil and e.kind == cekUnknownOption and e.value == "3"

suite "an empty argument after '--name=' is not an IndexDefect":
  test "it is taken as the (empty) value":
    check loadConf(@["--output=", ""]).output == some("")
    check loadConf(@["--output=", "", "--verbose"]).verbose

suite "shell completion is left to a quitting caller":
  test "a COMP_LINE in the environment does not short-circuit the parse":
    # The completion path prints candidates and returns a DEFAULT
    # configuration; a library caller would have recorded every option as
    # absent.
    putEnv("COMP_LINE", "prog --out")
    putEnv("COMP_POINT", "10")
    defer:
      delEnv("COMP_LINE")
      delEnv("COMP_POINT")
    let c = loadConf(@["--output", "a", "--verbose"])
    check c.output == some("a") and c.verbose

suite "negatableSwitches = false":
  proc strictConf(args: seq[string]): Conf {.raises: [ConfigurationError].} =
    Conf.load(cmdLine = args, quitOnFailure = false, envVarsPrefix = "",
              negatableSwitches = false)

  test "a switch given a false value is refused":
    for v in ["false", "off", "no", "0"]:
      var e: ref ConfigurationError = nil
      try:
        discard strictConf(@["--select-fast=" & v])
      except ConfigurationError as err:
        e = err
      check e != nil
      if e != nil:
        check e.kind == cekInvalidValue
        check e.option == "--select-fast"
        check e.value == v
        check "takes no false value" in e.msg

  test "a true value and the bare switch still apply":
    check strictConf(@["--verbose=true"]).verbose
    check strictConf(@["--select-fast=on"]).sel == some("fast")
    check strictConf(@["--verbose"]).verbose

  test "an unreadable value is still the setter's invalid value":
    var e: ref ConfigurationError = nil
    try:
      discard strictConf(@["--verbose=maybe"])
    except ConfigurationError as err:
      e = err
    check e != nil and e.kind == cekInvalidValue
    check e != nil and "takes no false value" notin e.msg

  test "the default still accepts the negated spelling":
    check not loadConf(@["--verbose=false"]).verbose
