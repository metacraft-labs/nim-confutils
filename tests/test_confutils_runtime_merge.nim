# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: two ``RuntimeCommandSurface`` instances can be merged.
# This is used by the help delegate when combining multiple component
# descriptions (typed config, capability JSON, registry data).

import
  unittest2,
  ../confutils/runtime_surface

suite "M6: runtime surface merge":
  test "merging two disjoint surfaces unions all commands and flags":
    let a = newRuntimeCommandSurface(
      programName = "ct",
      version = "1.0",
      globalFlags = @[newRuntimeFlag(name = "verbose", short = 'v')],
      commands = @[
        newRuntimeCommand(name = "record", description = "from typed config"),
      ])
    let b = newRuntimeCommandSurface(
      programName = "",  # leave scalar metadata alone
      globalFlags = @[newRuntimeFlag(name = "quiet", short = 'q')],
      commands = @[
        newRuntimeCommand(name = "replay", description = "from capability"),
      ])

    let merged = merge(a, b)

    # Metadata from ``a`` is preserved when ``b`` is empty.
    check merged.programName == "ct"
    check merged.version == "1.0"

    # Union semantics for global flags.
    check merged.globalFlags.len == 2
    check merged.globalFlags.hasFlag("verbose")
    check merged.globalFlags.hasFlag("quiet")

    # Union semantics for commands.
    check merged.commands.len == 2
    check merged.hasCommand("record")
    check merged.hasCommand("replay")

  test "colliding commands and flags: later one wins, fields merged":
    let baseRecord = newRuntimeCommand(
      name = "record",
      description = "old description",
      flags = @[newRuntimeFlag(name = "output", description = "old")],
      note = "")
    let augRecord = newRuntimeCommand(
      name = "record",
      description = "new description",
      flags = @[newRuntimeFlag(name = "output", description = "new"),
                newRuntimeFlag(name = "extra", description = "added")],
      note = "license: enterprise")

    let a = newRuntimeCommandSurface(
      programName = "ct",
      globalFlags = @[newRuntimeFlag(name = "config", description = "old")],
      commands = @[baseRecord])
    let b = newRuntimeCommandSurface(
      programName = "ct-merged",
      globalFlags = @[newRuntimeFlag(name = "config", description = "new")],
      commands = @[augRecord])

    let merged = merge(a, b)

    # Scalar metadata from ``b`` wins when non-empty.
    check merged.programName == "ct-merged"

    # Flag collision: the augmented description wins, but no duplicate.
    check merged.globalFlags.len == 1
    check merged.globalFlags[0].description == "new"

    # Command collision: kept once with merged data.
    check merged.commands.len == 1
    let rec = merged.commands[0]
    check rec.description == "new description"
    check rec.note == "license: enterprise"

    # Flag merge inside the collided command.
    check rec.flags.len == 2
    check rec.flags.hasFlag("output")
    check rec.flags.hasFlag("extra")
    check rec.flags[rec.flags.findFlagIdx("output")].description == "new"

  test "scalar metadata from b only wins when non-empty":
    let a = newRuntimeCommandSurface(programName = "ct", version = "1.0",
                                     description = "kept")
    let b = newRuntimeCommandSurface(programName = "", version = "",
                                     description = "")
    let merged = merge(a, b)
    check merged.programName == "ct"
    check merged.version == "1.0"
    check merged.description == "kept"
