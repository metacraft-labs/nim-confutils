## test_cs_m10_classic_help: a command line moved from a confutils
## configuration type onto a clispec description keeps its help screens and
## its runtime surface.
##
## ``classic_help_conf`` is a confutils type and ``classic_help_spec`` its
## clispec description. For every command and for several terminal widths
## (the narrow-terminal layout, below 36 columns for the descriptions,
## included), the help confutils' own ``load`` prints for ``<command>
## --help`` must be byte for byte what ``cliClassicHelp`` renders from the
## description, and what ``showClassicHelp`` writes to stdout with the
## width taken from ``COLUMNS``. ``surfaceFromModel`` of the description
## must equal ``surfaceFromType`` of the type, field by field.
##
## What confutils prints is observed, not restated: the test compiles
## ``classic_help_probe`` (with the compiler that built it, the flags in
## ``NIMFLAGS`` and, in a checkout that pins them, the dependency paths of
## ``confutilsTestPaths``, as ``test_cs_m9_combine_signature_checked`` does)
## and runs it, which calls confutils' loader and captures its stdout. It
## is compiled once more with ``-d:confutils_no_colors``, where both
## renderers must still agree and differ from the coloured screen only by
## the colour codes.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ./classic_help_conf, ./classic_help_spec

const
  probeSource = currentSourcePath().parentDir() / "classic_help_probe.nim"
  repoDir = currentSourcePath().parentDir().parentDir().parentDir()
  confutilsTestPaths {.strdefine.} = ""
    ## ``|``-separated dependency directories, set by ``config.nims`` in a
    ## checkout that pins them (empty: Nimble resolves the dependencies).
  commandPaths = [@[], @["build"], @["print"], @["run"], @["remote"],
                  @["remote", "push"], @["remote", "pull"], @["plain"]]
  widths = [20, 40, 60, 80, 120, 250]

proc compilerExe(): string =
  result = getCurrentCompilerExe()
  if not fileExists(result):
    result = findExe("nim")

proc buildProbe(dir: string; defines: openArray[string]):
    tuple[exe, output: string; exitCode: int] =
  ## Compiles ``classic_help_probe`` into ``dir``. Confutils' loader
  ## assigns the subcommand discriminator of an object whose default branch
  ## has fields, which needs ``nimOldCaseObjects``, as programs built on it
  ## use.
  createDir(dir)
  result.exe = dir / "classic_help_probe".addFileExt(ExeExt)
  var args = @[compilerExe(), "c", "--hints:off", "--warnings:off",
    "--skipParentCfg", "--skipUserCfg", "-d:nimOldCaseObjects",
    "--path:" & repoDir]
  if confutilsTestPaths.len > 0:
    args.add("--noNimblePath")
    for path in confutilsTestPaths.split('|'):
      args.add("--path:" & path)
  for flag in getEnv("NIMFLAGS").splitWhitespace():
    args.add(flag)
  for d in defines:
    args.add("-d:" & d)
  args.add(["--nimcache:" & dir / "nimcache", "--out:" & result.exe,
            probeSource])
  let (output, exitCode) = execCmdEx(quoteShellCommand(args))
  result.output = output
  result.exitCode = exitCode

proc runProbe(exe, mode: string; words: seq[string];
              width: int): tuple[output: string; exitCode: int] =
  ## Runs the probe with ``COLUMNS=<width>``; stdout only.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["COLUMNS"] = $width
  let p = startProcess(exe, args = @[mode] & words, env = env,
                       options = {})
  let output = p.outputStream.readAll()
  result = (output, p.waitForExit())
  p.close()

proc programNameOf(screen: string): string =
  ## The program name a coloured confutils help screen starts its usage
  ## line with. Which name confutils uses is its own business (the
  ## executable's name, or a fixed one in a fork), so the test reads it
  ## from confutils' output and renders the description with the same.
  let usage = screen.find("Usage: ")
  if usage < 0: return ""
  let start = screen.find("\e[36m", usage)
  if start < 0: return ""
  let stop = screen.find("\e[0m", start)
  if stop < 0: return ""
  screen[start + "\e[36m".len ..< stop]

proc visible(s: string): string =
  ## ``s`` with escapes made readable, for a failure message.
  s.multiReplace(("\e", "\\e"))

proc firstDifference(a, b: string): string =
  var i = 0
  while i < a.len and i < b.len and a[i] == b[i]:
    inc i
  "first difference at byte " & $i & ":\n  confutils: " &
    visible(a[max(0, i - 40) ..< min(a.len, i + 40)]) & "\n  classic:   " &
    visible(b[max(0, i - 40) ..< min(b.len, i + 40)])

proc withoutColours(s: string): string =
  ## ``s`` without the style and colour codes the renderers write (the
  ## resets stay, as they do under ``confutils_no_colors``).
  s.multiReplace(("\e[1m", ""), ("\e[33m", ""), ("\e[34m", ""),
                 ("\e[36m", ""))

proc surfaceDiff(path: string; a, b: RuntimeFlag): seq[string] =
  template cmpField(f: untyped) =
    if a.f != b.f:
      result.add(path & "." & astToStr(f) & ": " & $a.f & " vs " & $b.f)
  cmpField(name)
  cmpField(short)
  cmpField(description)
  cmpField(typeHint)
  cmpField(required)
  cmpField(default)
  cmpField(longDescription)
  cmpField(aliases)
  cmpField(takesValue)
  cmpField(valueOptional)
  cmpField(valueName)

proc surfaceDiff(path: string; a, b: RuntimeCommand): seq[string] =
  if a.name != b.name:
    result.add(path & ".name: " & a.name & " vs " & b.name)
  if a.description != b.description:
    result.add(path & ".description: " & a.description & " vs " &
               b.description)
  if a.fileTypes != b.fileTypes or a.projectMarkers != b.projectMarkers or
      a.note != b.note:
    result.add(path & ": annotations differ")
  if a.flags.len != b.flags.len:
    result.add(path & ".flags.len: " & $a.flags.len & " vs " &
               $b.flags.len)
  for i in 0 ..< min(a.flags.len, b.flags.len):
    result.add(surfaceDiff(path & ".flags[" & $i & "]", a.flags[i],
                           b.flags[i]))
  if a.subcommands.len != b.subcommands.len:
    result.add(path & ".subcommands.len: " & $a.subcommands.len & " vs " &
               $b.subcommands.len)
  for i in 0 ..< min(a.subcommands.len, b.subcommands.len):
    result.add(surfaceDiff(path & "." & a.subcommands[i].name,
                           a.subcommands[i], b.subcommands[i]))

proc surfaceDiff(a, b: RuntimeCommandSurface): seq[string] =
  if a.programName != b.programName or a.version != b.version or
      a.description != b.description:
    result.add("program metadata differs")
  if a.globalFlags.len != b.globalFlags.len:
    result.add("globalFlags.len: " & $a.globalFlags.len & " vs " &
               $b.globalFlags.len)
  for i in 0 ..< min(a.globalFlags.len, b.globalFlags.len):
    result.add(surfaceDiff("globalFlags[" & $i & "]", a.globalFlags[i],
                           b.globalFlags[i]))
  if a.commands.len != b.commands.len:
    result.add("commands.len: " & $a.commands.len & " vs " &
               $b.commands.len)
  for i in 0 ..< min(a.commands.len, b.commands.len):
    result.add(surfaceDiff(a.commands[i].name, a.commands[i],
                           b.commands[i]))

suite "test_cs_m10_classic_help":
  let scratch = createTempDir("confutils_cs_m10_help_", "")
  let coloured = buildProbe(scratch / "colours", [])
  let plain = buildProbe(scratch / "no_colours", ["confutils_no_colors"])

  let programName = programNameOf(
    runProbe(coloured.exe, "confutils", @[], 80).output)

  test "the probe builds, with and without colours":
    check coloured.exitCode == 0
    check plain.exitCode == 0
    if coloured.exitCode != 0: echo coloured.output
    if plain.exitCode != 0: echo plain.output
    # The program name is a single word, read from confutils' own screen.
    check programName.len > 0
    check ' ' notin programName and '\e' notin programName

  for words in commandPaths:
    test "help of '" & words.join(" ") & "' is confutils' at every width":
      var compared = 0
      for width in widths:
        let expected = runProbe(coloured.exe, "confutils", words, width)
        check expected.exitCode == 0
        # The screen is not trivially short.
        check expected.output.startsWith(banner & "\p\p")
        check "Usage:" in expected.output
        let rendered = FixSpec.cliClassicHelp(words, programName, banner,
                                              width)
        check rendered == expected.output
        if rendered != expected.output:
          echo "  width ", width, ": ",
            firstDifference(expected.output, rendered)
        let shown = runProbe(coloured.exe, "classic",
                             @[programName] & words, width)
        check shown.exitCode == 0
        check shown.output == expected.output
        inc compared
      check compared == widths.len

  test "the narrow and the wide layout are both exercised":
    let narrow = FixSpec.cliClassicHelp(["print"], programName, "", 40)
    let wide = FixSpec.cliClassicHelp(["print"], programName, "", 80)
    # Narrow: a description starts on a line of its own, one blank in.
    check "\p Only events of this kind." in narrow
    check "--filter    \e[0m  Only events of this kind." in wide

  test "without colours, both renderers agree and only the colours differ":
    for words in commandPaths:
      let expected = runProbe(plain.exe, "confutils", words, 80)
      let shown = runProbe(plain.exe, "classic", @[programName] & words, 80)
      check expected.exitCode == 0
      check shown.exitCode == 0
      check shown.output == expected.output
      check "\e[3" notin expected.output
      check expected.output == withoutColours(
        FixSpec.cliClassicHelp(words, programName, banner, 80))

  test "the program name defaults to the description's":
    check FixSpec.cliClassicHelp(["plain"], width = 80).contains(
      "\e[36mfix plain\e[0m")

  test "a word that names no command is a usage error":
    expect CliUsageError:
      discard FixSpec.cliClassicHelp(["bogus"], programName, "", 80)

  test "surfaceFromModel is surfaceFromType, field by field":
    let fromType = surfaceFromType(FixConf, "fix")
    let fromModel = FixSpec.surfaceFromModel("fix", "noCommand")
    let diff = surfaceDiff(fromType, fromModel)
    check diff.len == 0
    for d in diff:
      echo "  ", d
    check fromModel == fromType
    # Not vacuous: the surface has the fixture's shape.
    check fromType.globalFlags.len == 5
    check fromType.commands.len == 6
    check fromType.commands[0].name == "noCommand"

  test "without a name for the default command, it is left out":
    let surface = FixSpec.surfaceFromModel("fix")
    check surface.commands.len == 5
    check surface.commands[0].name == "build"
    check surface.commands[3].subcommands.len == 2

  removeDir(scratch)
