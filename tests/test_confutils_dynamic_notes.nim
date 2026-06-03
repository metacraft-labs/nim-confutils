# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: a ``RuntimeCommand`` with a non-empty ``note`` field renders
# the note alongside the command in help output. The launcher uses this to
# annotate commands with dynamic information (license status, deprecation,
# experimental flag, etc.) that is unknown at compile time.

import
  std/strutils,
  unittest2,
  ../confutils/runtime_surface

suite "M6: dynamic notes":
  test "note appears next to the command name in rendered help":
    let surface = newRuntimeCommandSurface(
      programName = "ct",
      commands = @[
        newRuntimeCommand(
          name = "record",
          description = "record a program",
          note = "license: enterprise"),
        newRuntimeCommand(
          name = "replay",
          description = "replay a recording",
          note = "experimental"),
        newRuntimeCommand(
          name = "info",
          description = "show metadata"),
      ])

    let help = renderHelpFromSurface(surface)

    # Each note must appear in the help.
    check "license: enterprise" in help
    check "experimental" in help

    # Notes must appear *next to* their command, not in a separate block.
    let recordLineIdx = help.find("record")
    let licenseIdx = help.find("license: enterprise")
    check recordLineIdx >= 0
    check licenseIdx >= 0
    # The note must appear after the command name on (or near) the same line:
    # the renderer places the note in brackets on the command's line.
    let helpUpToNote = help[0 .. licenseIdx - 1]
    check helpUpToNote.endsWith("record  record a program  [")

    # A command without a note must not produce a stray "[]" annotation.
    let infoIdx = help.find("info")
    check infoIdx >= 0
    let infoLineEnd = help.find('\n', infoIdx)
    let infoLine = help[infoIdx .. infoLineEnd - 1]
    check "[" notin infoLine

  test "single command in isolation still renders its note":
    let cmd = newRuntimeCommand(name = "record", note = "beta")
    let rendered = renderCommand(cmd)
    check "record" in rendered
    check "beta" in rendered
    check "[beta]" in rendered

  test "an empty note does not change rendering":
    let withNote = newRuntimeCommand(name = "x", note = "")
    let rendered = renderCommand(withNote)
    check rendered == "x\n"
