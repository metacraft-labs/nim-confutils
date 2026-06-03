# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: ``RuntimeCommandSurface`` populated at runtime produces
# correct help text output.

import
  std/strutils,
  unittest2,
  ../confutils/runtime_surface

suite "M6: runtime surface help":
  test "help text contains program name, version, commands and flags":
    # Build the surface entirely by hand -- no Nim type involved.
    let surface = newRuntimeCommandSurface(
      programName = "ct",
      version = "1.2.3",
      description = "CodeTracer launcher",
      globalFlags = @[
        newRuntimeFlag(name = "verbose", short = 'v',
                       description = "enable verbose logging"),
        newRuntimeFlag(name = "config", typeHint = "PATH",
                       description = "config file location",
                       default = "/etc/ct.conf"),
      ],
      commands = @[
        newRuntimeCommand(
          name = "record",
          description = "record a program",
          flags = @[
            newRuntimeFlag(name = "output", short = 'o', typeHint = "DIR",
                           description = "output directory", required = true),
            newRuntimeFlag(name = "program", description = "program to run"),
          ],
          fileTypes = @[".py", ".rb"],
          projectMarkers = @["Cargo.toml", "package.json"],
        ),
        newRuntimeCommand(
          name = "replay",
          description = "replay a recording",
          flags = @[
            newRuntimeFlag(name = "trace", typeHint = "PATH",
                           description = "trace path", required = true),
          ],
        ),
      ],
    )

    let help = renderHelpFromSurface(surface)

    # Program metadata must appear.
    check "ct" in help
    check "1.2.3" in help
    check "CodeTracer launcher" in help

    # Global flags must be rendered.
    check "--verbose" in help
    check "-v" in help
    check "enable verbose logging" in help
    check "--config" in help
    check "<PATH>" in help
    check "/etc/ct.conf" in help

    # Commands must be rendered with their descriptions.
    check "record" in help
    check "record a program" in help
    check "replay" in help
    check "replay a recording" in help

    # Per-command flags appear under the right command.
    check "--output" in help
    check "-o" in help
    check "<DIR>" in help
    check "(required)" in help
    check "--trace" in help

    # File types and project markers must surface in the help output.
    check ".py" in help
    check ".rb" in help
    check "Cargo.toml" in help

    # Section headings must be present.
    check "Global options" in help
    check "Commands:" in help

  test "usage line summarises the surface":
    let surface = newRuntimeCommandSurface(
      programName = "ct",
      commands = @[newRuntimeCommand(name = "info")],
      globalFlags = @[newRuntimeFlag(name = "verbose")],
    )
    let usage = renderUsageFromSurface(surface)
    check "Usage: ct" in usage
    check "[GLOBAL OPTIONS]" in usage
    check "<command>" in usage

  test "renderFlagsSection omits when no flags":
    check renderFlagsSection(@[], "Options") == ""

  test "flagSwitches handles short-only, long-only and both":
    check flagSwitches(newRuntimeFlag(name = "log", short = 'l')) == "-l, --log"
    check flagSwitches(newRuntimeFlag(name = "", short = 'q')) == "-q"
    check flagSwitches(newRuntimeFlag(name = "only-long")) == "    --only-long"
