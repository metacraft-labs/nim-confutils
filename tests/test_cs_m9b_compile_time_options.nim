# nim-confutils
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## test_cs_m9b_compile_time_options: `{.flagDefine.}` and `{.enumDefine.}`
## (`confutils/defines`) turn `-d:` values into typed constants.
##
## The fixture library under `tests/defines/fixtures/` declares its options
## with the macros, and the fixture program prints them on one line. Each
## case compiles the program with the compiler that built this test, with
## only the checkout root on the path (the module depends on the standard
## library alone) and some `-d:` switches, runs it and compares the whole
## line. An invalid value must fail to compile with the exact message naming
## the option, the value and the allowed values. Observing defines and compile
## errors needs the compiler, so nothing is mocked.
##
## The parsing functions are also checked directly, at compile time and at
## run time.

import std/[os, osproc, strutils, tempfiles]
import unittest2
import ../confutils/defines

const
  fixturesDir = currentSourcePath().parentDir() / "defines" / "fixtures"
  repoDir = currentSourcePath().parentDir().parentDir()
  fixtureProgram = fixturesDir / "defines_fixture.nim"
  defaultLine =
    "traces=false threads=true level=INFO endings=platform " &
    "colors=NativeColors flag=false"

proc compilerExe(): string =
  result = getCurrentCompilerExe()
  if not fileExists(result):
    result = findExe("nim")

let scratch = createTempDir("confutils_cs_m9b_", "")

type Build = object
  exitCode: int
  output: string
  exe: string

var buildCount = 0

proc buildFixture(defines: openArray[string]): Build =
  inc buildCount
  result.exe = scratch / ("fixture_" & $buildCount).addFileExt(ExeExt)
  var args = @[compilerExe(), "c", "--hints:off", "--skipParentCfg",
    "--skipUserCfg", "--styleCheck:usages", "--styleCheck:error",
    "--path:" & repoDir, "--nimcache:" & scratch / "nimcache",
    "--out:" & result.exe]
  args.add(defines)
  args.add(fixtureProgram)
  (result.output, result.exitCode) = execCmdEx(quoteShellCommand(args))

proc fixtureLine(defines: openArray[string]): string =
  ## The fixture's printed line, or a description of the failure.
  let build = buildFixture(defines)
  if build.exitCode != 0:
    return "<compile failed: " & build.output & ">"
  let (output, exitCode) = execCmdEx(quoteShellCommand([build.exe]))
  if exitCode != 0:
    return "<run failed (" & $exitCode & "): " & output & ">"
  output.strip(leading = false, chars = {'\n', '\r'})

proc withField(field, value: string): string =
  ## `defaultLine` with one `field=value` replaced.
  var parts = defaultLine.split(' ')
  for part in parts.mitems:
    if part.startsWith(field & "="):
      part = field & "=" & value
  parts.join(" ")

proc compileError(defines: openArray[string]): tuple[failed: bool,
                                                     errors: seq[string]] =
  ## Whether the build failed, and the messages of its `Error:` lines.
  let build = buildFixture(defines)
  result.failed = build.exitCode != 0 and not fileExists(build.exe)
  for line in build.output.splitLines():
    let at = line.find(" Error: ")
    if at >= 0:
      result.errors.add(line[at + " Error: ".len .. ^1])

const
  flagNote = "in any letter case; a bare -d:$1 means true"
  flagAllowed = "yes, 1, on, true, no, 0, off, false, none"

proc flagError(name, value: string): string =
  "invalid value '" & value & "' for the compile-time option '" & name &
    "' (-d:" & name & "=" & value & "); allowed values: " & flagAllowed &
    " (" & flagNote % name & ")"

proc enumError(name, value, allowed, note: string): string =
  "invalid value '" & value & "' for the compile-time option '" & name &
    "' (-d:" & name & "=" & value & "); allowed values: " & allowed &
    " (" & note & ")"

suite "test_cs_m9b_compile_time_options: parsing functions":
  test "the spelling sets":
    check truthySpellings == ["yes", "1", "on", "true"]
    check falsySpellings == ["no", "0", "off", "false", "none"]

  test "parseFlagValue at compile time and at run time":
    const atCompileTime = (parseFlagValue("YES"), parseFlagValue("None"),
                           parseFlagValue("maybe"))
    check atCompileTime == (some(true), some(false), none(bool))
    for s in ["yes", "1", "on", "true", "Yes", "ON", "TRUE", "tRuE"]:
      check parseFlagValue(s) == some(true)
    for s in ["no", "0", "off", "false", "none", "No", "OFF", "False", "NONE"]:
      check parseFlagValue(s) == some(false)
    for s in ["", "y", "n", "2", "enable", " yes", "yes "]:
      check parseFlagValue(s) == none(bool)

  test "parseEnumValue matches names and string values, ignoring style":
    type
      Level = enum TRACE, DEBUG, NOTICE_LEVEL
      Ends = enum winEnds = "windows", posixEnds = "posix"
    const atCompileTime = parseEnumValue[Level]("notice_level")
    check atCompileTime == some(NOTICE_LEVEL)
    check parseEnumValue[Level]("trace") == some(TRACE)
    check parseEnumValue[Level]("Debug") == some(DEBUG)
    check parseEnumValue[Level]("noticelevel") == some(NOTICE_LEVEL)
    check parseEnumValue[Level]("NoticeLevel") == some(NOTICE_LEVEL)
    check parseEnumValue[Level]("warn") == none(Level)
    check parseEnumValue[Ends]("WINDOWS") == some(winEnds)
    check parseEnumValue[Ends]("posix_ends") == some(posixEnds)
    check parseEnumValue[Ends]("unix") == none(Ends)
    check enumValueSpellings[Level]() == @["TRACE", "DEBUG", "NOTICE_LEVEL"]
    check enumValueSpellings[Ends]() ==
      @["windows (winEnds)", "posix (posixEnds)"]

  test "an enum with holes":
    # This module does not import `std/enumutils`, which iterates such an
    # enum; the functions must not need it in the caller's scope.
    type Holey = enum holeA = 1, holeB = 5, holeC = "c"
    check parseEnumValue[Holey]("hole_b") == some(holeB)
    check parseEnumValue[Holey]("C") == some(holeC)
    check parseEnumValue[Holey]("hole") == none(Holey)
    check enumValueSpellings[Holey]() == @["holeA", "holeB", "c (holeC)"]

  test "error messages":
    check flagDefineError("lib_x", "maybe") == flagError("lib_x", "maybe")
    type Level = enum TRACE, DEBUG
    check enumDefineError[Level]("lib_level", "warn") ==
      enumError("lib_level", "warn", "TRACE, DEBUG",
                "letter case and underscores are ignored")
    check enumDefineError[Level]("lib_level", "warn", falsyMapped = true) ==
      enumError("lib_level", "warn", "TRACE, DEBUG",
                "letter case and underscores are ignored; " &
                "or one of no, 0, off, false, none")

suite "test_cs_m9b_compile_time_options: -d: values reach the constants":
  test "no -d: keeps every default":
    check fixtureLine([]) == defaultLine

  test "every truthy spelling, and mixed case, sets a flag":
    for spelling in ["yes", "1", "on", "true", "Yes", "ON", "True", "yEs"]:
      checkpoint spelling
      check fixtureLine(["-d:fixture_traces=" & spelling]) ==
        withField("traces", "true")

  test "a bare -d:name is truthy":
    check fixtureLine(["-d:fixture_traces"]) == withField("traces", "true")

  test "every falsy spelling, and mixed case, clears a flag":
    for spelling in ["no", "0", "off", "false", "none",
                     "NO", "Off", "FALSE", "nOnE"]:
      checkpoint spelling
      check fixtureLine(["-d:fixture_threads=" & spelling]) ==
        withField("threads", "false")

  test "a falsy value on a false flag and a truthy one on a true flag":
    check fixtureLine(["-d:fixture_traces=off", "-d:fixture_threads=on"]) ==
      defaultLine

  test "each enum value, in varied letter case and underscores":
    for (value, expected) in [("trace", "TRACE"), ("Debug", "DEBUG"),
                              ("INFO", "INFO"), ("notice_level", "NOTICE_LEVEL"),
                              ("NoticeLevel", "NOTICE_LEVEL")]:
      checkpoint value
      check fixtureLine(["-d:fixture_level=" & value]) ==
        withField("level", expected)

  test "an enum with string values accepts the strings and the names":
    for (value, expected) in [("windows", "windows"), ("POSIX", "posix"),
                              ("Platform", "platform"),
                              ("windowsEndings", "windows"),
                              ("posix_endings", "posix")]:
      checkpoint value
      check fixtureLine(["-d:fixture_endings=" & value]) ==
        withField("endings", expected)

  test "explicit define names, and offValue for falsy spellings":
    check fixtureLine(["-d:fixture.colors=ansi_colors"]) ==
      withField("colors", "AnsiColors")
    check fixtureLine(["-d:fixture.colors=off"]) ==
      withField("colors", "NoColors")
    check fixtureLine(["-d:fixture.colors=None"]) ==
      withField("colors", "NoColors")
    check fixtureLine(["-d:fixture.flag=on"]) == withField("flag", "true")
    check fixtureLine(["-d:fixture.flag"]) == withField("flag", "true")
    # The constant's own name is not the define's name.
    check fixtureLine(["-d:fixtureColors=AnsiColors",
                       "-d:fixtureFlag=on"]) == defaultLine

  test "several options at once":
    check fixtureLine(["-d:fixture_traces=1", "-d:fixture_threads=0",
                       "-d:fixture_level=debug", "-d:fixture_endings=posix",
                       "-d:fixture.colors=no", "-d:fixture.flag=YES"]) ==
      "traces=true threads=false level=DEBUG endings=posix " &
      "colors=NoColors flag=true"

suite "test_cs_m9b_compile_time_options: invalid values are compile errors":
  test "a flag with an unknown value":
    for (define, name, value) in [
        ("-d:fixture_traces=maybe", "fixture_traces", "maybe"),
        ("-d:fixture_threads=2", "fixture_threads", "2"),
        ("-d:fixture.flag=enable", "fixture.flag", "enable")]:
      checkpoint define
      check compileError([define]) == (true, @[flagError(name, value)])

  test "an enum with an unknown value":
    check compileError(["-d:fixture_level=warn"]) ==
      (true, @[enumError("fixture_level", "warn",
                         "TRACE, DEBUG, INFO, NOTICE_LEVEL",
                         "letter case and underscores are ignored")])
    # A bare -d: gives "true", which is no value of the enum.
    check compileError(["-d:fixture_level"]) ==
      (true, @[enumError("fixture_level", "true",
                         "TRACE, DEBUG, INFO, NOTICE_LEVEL",
                         "letter case and underscores are ignored")])
    # Without offValue a falsy spelling is not accepted.
    check compileError(["-d:fixture_level=off"]) ==
      (true, @[enumError("fixture_level", "off",
                         "TRACE, DEBUG, INFO, NOTICE_LEVEL",
                         "letter case and underscores are ignored")])
    check compileError(["-d:fixture_endings=unix"]) ==
      (true, @[enumError("fixture_endings", "unix",
                         "windows (windowsEndings), posix (posixEndings), " &
                         "platform (platformEndings)",
                         "letter case and underscores are ignored")])
    check compileError(["-d:fixture.colors=mono"]) ==
      (true, @[enumError("fixture.colors", "mono",
                         "NoColors, AnsiColors, NativeColors",
                         "letter case and underscores are ignored; " &
                         "or one of no, 0, off, false, none")])

  test "the error points at the option's declaration":
    let build = buildFixture(["-d:fixture_level=warn"])
    check build.exitCode != 0
    check (fixturesDir / "defines_fixture_lib.nim") & "(22, 3) Error: " &
      enumError("fixture_level", "warn", "TRACE, DEBUG, INFO, NOTICE_LEVEL",
                "letter case and underscores are ignored") in
      build.output.splitLines()

removeDir(scratch)
