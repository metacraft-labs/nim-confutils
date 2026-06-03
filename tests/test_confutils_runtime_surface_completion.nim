# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: ``RuntimeCommandSurface`` at runtime produces correct
# completion candidates.

import
  unittest2,
  ../confutils/runtime_surface

suite "M6: runtime surface completion":
  setup:
    let surface = newRuntimeCommandSurface(
      programName = "ct",
      globalFlags = @[
        newRuntimeFlag(name = "verbose", short = 'v'),
        newRuntimeFlag(name = "config", short = 'c'),
      ],
      commands = @[
        newRuntimeCommand(
          name = "record",
          flags = @[
            newRuntimeFlag(name = "output", short = 'o'),
            newRuntimeFlag(name = "program"),
          ],
          subcommands = @[
            newRuntimeCommand(name = "noir",
                              flags = @[newRuntimeFlag(name = "circuit")]),
          ],
        ),
        newRuntimeCommand(
          name = "replay",
          flags = @[
            newRuntimeFlag(name = "trace"),
          ],
        ),
      ],
    )

  test "all command and flag tokens are returned":
    let candidates = completionCandidates(surface)
    # Global flags surface as both long and short.
    check "--verbose" in candidates
    check "-v" in candidates
    check "--config" in candidates
    check "-c" in candidates
    # Top-level command names.
    check "record" in candidates
    check "replay" in candidates
    # Per-command flags.
    check "--output" in candidates
    check "-o" in candidates
    check "--program" in candidates
    check "--trace" in candidates
    # Nested sub-command and its flag.
    check "noir" in candidates
    check "--circuit" in candidates

  test "prefix filtering narrows the candidate list":
    let recordOnly = completionsMatching(surface, "rec")
    check recordOnly == @["record"]

    let dashes = completionsMatching(surface, "--")
    # All long flags begin with --; confirm the well-known set.
    check "--verbose" in dashes
    check "--config" in dashes
    check "--output" in dashes
    check "--program" in dashes
    check "--trace" in dashes
    check "--circuit" in dashes
    for cand in dashes:
      check cand.len >= 2 and cand[0] == '-' and cand[1] == '-'

  test "lookup helpers find existing commands and flags":
    check surface.hasCommand("record")
    check surface.hasCommand("replay")
    check not surface.hasCommand("missing")
    check surface.findCommandIdx("record") == 0
    check surface.findCommandIdx("replay") == 1
    check surface.findCommandIdx("missing") == -1
    check surface.globalFlags.hasFlag("verbose")
    check not surface.globalFlags.hasFlag("missing")
