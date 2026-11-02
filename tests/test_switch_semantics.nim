# nim-confutils
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Which tokens a switch consumes, and which option a short key names.
##
## * An `Option[bool]` field is a switch exactly like a `bool` one: it never
##   takes its value from the next token, on either side of a positional
##   argument. As a value-taking option it spent `--flag <path>`'s path as its
##   value and refused it as "not a valid boolean value", and `<path> --flag`
##   left it waiting for a value, dropped.
## * A single-character abbreviation matches case-sensitively, so `-f` and
##   `-F` are distinct options. Matched style-insensitively, `-F` resolved to
##   whichever of the two was declared first. Long names, and multi-character
##   abbreviations, keep their `cmpIgnoreStyle` matching (case and `_`
##   ignored).
## * A value-taking switch with no value left is reported, never dropped.
##
## Real command lines through the real `load`; no mocks.

import
  std/options,
  unittest2,
  ../confutils

type
  SwitchConf = object
    path {.
      argument
      desc: "A positional argument"
      name: "path" }: string

    verify {.
      desc: "An Option[bool] switch"
      abbr: "V"
      name: "verify" }: Option[bool]

    follow {.
      desc: "A bool switch with an upper-case abbreviation"
      abbr: "F"
      defaultValue: false
      name: "follow" }: bool

    filter {.
      desc: "A value-taking option with the lower-case abbreviation"
      abbr: "f"
      name: "filter" }: Option[string]

    outputDir {.
      desc: "A long name, matched style-insensitively"
      name: "output-dir" }: Option[string]

    cooperative {.
      desc: "A multi-character abbreviation, a second LONG spelling"
      abbr: "coop"
      defaultValue: false
      name: "cooperative" }: bool

proc loadSwitches(args: seq[string]): SwitchConf {.raises: [ConfigurationError].} =
  SwitchConf.load(cmdLine = args, quitOnFailure = false, envVarsPrefix = "")

proc errorOf(args: seq[string]): ref ConfigurationError =
  try:
    discard loadSwitches(args)
  except ConfigurationError as e:
    return e
  nil

suite "Option[bool] is a switch":
  test "after a positional argument it is applied":
    let c = loadSwitches(@["p", "--verify"])
    check c.path == "p"
    check c.verify == some(true)

  test "before a positional argument it does not consume it":
    let c = loadSwitches(@["--verify", "p"])
    check c.path == "p"
    check c.verify == some(true)

  test "its short spelling behaves the same":
    let c = loadSwitches(@["-V", "p"])
    check c.path == "p"
    check c.verify == some(true)

  test "not given, it stays none":
    check loadSwitches(@["p"]).verify.isNone

  test "an explicit value still works":
    check loadSwitches(@["p", "--verify=false"]).verify == some(false)
    check loadSwitches(@["--verify=true", "p"]).verify == some(true)
    let e = errorOf(@["p", "--verify=maybe"])
    check e != nil and e.kind == cekInvalidValue

  test "it takes no value from the next token":
    # The token after a switch is a positional argument, so a second one is
    # an unexpected argument rather than the switch's value.
    let e = errorOf(@["p", "--verify", "false"])
    check e != nil and e.kind == cekUnexpectedArgument

  test "the runtime surface does not advertise a value":
    const surface = surfaceFromType(SwitchConf)
    let fl = surface.globalFlags
    check not fl[fl.findFlagIdx("verify")].takesValue
    check not fl[fl.findFlagIdx("follow")].takesValue
    check fl[fl.findFlagIdx("filter")].takesValue
    check fl[fl.findFlagIdx("output-dir")].takesValue

suite "a short abbreviation is case-sensitive":
  test "-F and -f name different options":
    let upper = loadSwitches(@["-F", "p"])
    check upper.follow
    check upper.filter.isNone
    check upper.path == "p"
    let lower = loadSwitches(@["-f", "errors", "p"])
    check not lower.follow
    check lower.filter == some("errors")
    check lower.path == "p"

  test "a short key in the wrong case is unknown when nothing else matches":
    let e = errorOf(@["-v", "p"])
    check e != nil and e.kind == cekUnknownOption

  test "long names keep their case-insensitive matching":
    check loadSwitches(@["p", "--output-dir", "o"]).outputDir == some("o")
    check loadSwitches(@["p", "--Output-Dir=o"]).outputDir == some("o")
    check loadSwitches(@["p", "--OUTPUT-DIR", "o"]).outputDir == some("o")
    check loadSwitches(@["p", "--FOLLOW"]).follow

  test "a multi-character abbreviation keeps its case-insensitive matching":
    # Only ONE-letter spellings became case-sensitive; `abbr: "coop"` is a
    # long spelling (`--coop`) and still ignores case.
    check loadSwitches(@["p", "--coop"]).cooperative
    check loadSwitches(@["p", "--COOP"]).cooperative

suite "a missing value is reported, not dropped":
  test "last on the command line":
    for spelling in ["--filter", "-f"]:
      let e = errorOf(@["p", spelling])
      check e != nil
      check e.kind == cekMissingValue
      check e.option == spelling
