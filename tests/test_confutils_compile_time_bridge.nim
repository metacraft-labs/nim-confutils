# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: the compile-time bridge ``surfaceFromType`` produces a
# runtime surface from a Nim configuration type whose rendered help matches
# the expected output produced via a hand-built surface. This proves that
# the bridge is transparent: the typed-config style funnels through the
# same runtime algorithms a fully dynamic surface would.

import
  std/[strutils, options],
  unittest2,
  ../confutils,
  ../confutils/runtime_surface

type
  Cmd = enum
    record = "Record a program"
    replay = "Replay a recording"

  BridgedCfg = object
    verbose {.
      desc: "enable verbose logging"
      abbr: "v"
      defaultValue: false }: bool
    config {.
      desc: "config file location"
      defaultValue: "/etc/ct.conf" }: string

    case cmd {.command, defaultValue: record.}: Cmd
    of record:
      output {.
        desc: "output directory"
        abbr: "o" }: string
    of replay:
      trace {.desc: "trace path".}: string

# Hand-built equivalent surface used to snapshot the expected behaviour.
proc handBuiltSurface(): RuntimeCommandSurface =
  newRuntimeCommandSurface(
    programName = "ct",
    globalFlags = @[
      newRuntimeFlag(name = "verbose", short = 'v',
                     description = "enable verbose logging",
                     typeHint = "bool",
                     required = false,
                     default = "false"),
      newRuntimeFlag(name = "config",
                     description = "config file location",
                     typeHint = "string",
                     required = false,
                     default = "/etc/ct.conf"),
    ],
    commands = @[
      newRuntimeCommand(name = "record",
                        description = "Record a program",
                        flags = @[
                          newRuntimeFlag(name = "output", short = 'o',
                                         description = "output directory",
                                         typeHint = "string",
                                         required = true)]),
      newRuntimeCommand(name = "replay",
                        description = "Replay a recording",
                        flags = @[
                          newRuntimeFlag(name = "trace",
                                         description = "trace path",
                                         typeHint = "string",
                                         required = true)]),
    ])

suite "M6: compile-time bridge":
  test "bridge produces a structurally identical surface to a hand-built one":
    let bridged = surfaceFromType(BridgedCfg, "ct")
    let expected = handBuiltSurface()

    check bridged.programName == expected.programName
    check bridged.globalFlags.len == expected.globalFlags.len
    for i in 0 ..< expected.globalFlags.len:
      check bridged.globalFlags[i].name == expected.globalFlags[i].name
      check bridged.globalFlags[i].short == expected.globalFlags[i].short
      check bridged.globalFlags[i].description ==
            expected.globalFlags[i].description
      check bridged.globalFlags[i].typeHint == expected.globalFlags[i].typeHint
      check bridged.globalFlags[i].required == expected.globalFlags[i].required
      check bridged.globalFlags[i].default == expected.globalFlags[i].default

    check bridged.commands.len == expected.commands.len
    for i in 0 ..< expected.commands.len:
      check bridged.commands[i].name == expected.commands[i].name
      check bridged.commands[i].description == expected.commands[i].description
      check bridged.commands[i].flags.len == expected.commands[i].flags.len
      for j in 0 ..< expected.commands[i].flags.len:
        check bridged.commands[i].flags[j].name ==
              expected.commands[i].flags[j].name
        check bridged.commands[i].flags[j].short ==
              expected.commands[i].flags[j].short
        check bridged.commands[i].flags[j].description ==
              expected.commands[i].flags[j].description
        check bridged.commands[i].flags[j].typeHint ==
              expected.commands[i].flags[j].typeHint
        check bridged.commands[i].flags[j].required ==
              expected.commands[i].flags[j].required

  test "bridged surface renders byte-equal help to the hand-built surface":
    let bridged = surfaceFromType(BridgedCfg, "ct")
    let expected = handBuiltSurface()
    check renderHelpFromSurface(bridged) == renderHelpFromSurface(expected)

  test "bridged help mentions every flag and command":
    let bridged = surfaceFromType(BridgedCfg, "ct")
    let help = renderHelpFromSurface(bridged)
    check "--verbose" in help
    check "-v" in help
    check "--config" in help
    check "record" in help
    check "Record a program" in help
    check "replay" in help
    check "Replay a recording" in help
    check "--output" in help
    check "--trace" in help

  test "bridged completion candidates include the typed config's flags/commands":
    let bridged = surfaceFromType(BridgedCfg, "ct")
    let candidates = completionCandidates(bridged)
    check "--verbose" in candidates
    check "-v" in candidates
    check "--config" in candidates
    check "record" in candidates
    check "replay" in candidates
    check "--output" in candidates
    check "-o" in candidates
    check "--trace" in candidates

  test "existing typed-config load still works (regression sanity)":
    # Use the typed-config code path that pre-dates M6 to prove that the
    # bridge is purely additive.
    let conf = BridgedCfg.load(@["--verbose=true", "record",
                                  "--output=/tmp/out"])
    check conf.verbose == true
    case conf.cmd
    of record:
      check conf.output == "/tmp/out"
    of replay:
      check false  # unreachable
