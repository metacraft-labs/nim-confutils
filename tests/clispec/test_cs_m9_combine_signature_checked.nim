## test_cs_m9_combine_signature_checked: a combine proc (``merge = <proc>``)
## that cannot be called as ``proc (candidates:
## openArray[CliSourcedValue[T]]): T`` is a compile error naming the
## parameter. Confutils calls the combine procs, so ``cliConfiguration``
## checks them; clispec records them in the model without checking.
##
## Each fixture under ``tests/clispec/fixtures/`` has exactly one line
## marked ``# clispec-invalid`` and states the expected message in an
## ``## expect:`` header. The test runs the real compiler (``nim check``,
## the compiler that built this test, with the flags in ``NIMFLAGS``, which
## is how confutils' test task passes dependency paths) on the fixture,
## requiring a failure carrying the message, and on a copy without the
## marked line, requiring success: the vacuity guard showing the error came
## from that line. The checkout's root is on the path, so a fixture imports
## ``confutils/clispec_config``. Inside a codetracer checkout,
## ``tests/clispec/config.nims`` passes the pinned dependency paths it builds
## this test with as ``confutilsTestPaths``, and they are given to the
## compiler the same way. Observing a compile error's message needs the compiler,
## so nothing is mocked.

import std/[os, osproc, strutils, tempfiles, unittest]

const
  fixturesDir = currentSourcePath().parentDir() / "fixtures"
  repoDir = currentSourcePath().parentDir().parentDir().parentDir()
  invalidMarker = "# clispec-invalid"
  expectPrefix = "## expect: "
  confutilsTestPaths {.strdefine.} = ""
    ## ``|``-separated dependency directories, set by ``config.nims`` in a
    ## checkout that pins them (empty: Nimble resolves the dependencies).

proc compilerExe(): string =
  result = getCurrentCompilerExe()
  if not fileExists(result):
    result = findExe("nim")

proc nimCheck(file, nimcache: string): tuple[output: string, exitCode: int] =
  var args = @[compilerExe(), "check", "--hints:off", "--skipParentCfg",
    "--skipUserCfg", "--path:" & repoDir]
  if confutilsTestPaths.len > 0:
    args.add("--noNimblePath")
    for dir in confutilsTestPaths.split('|'):
      args.add("--path:" & dir)
  for flag in getEnv("NIMFLAGS").splitWhitespace():
    args.add(flag)
  args.add(["--nimcache:" & nimcache, file])
  execCmdEx(quoteShellCommand(args))

proc expectedMessage(text: string): string =
  for line in text.splitLines():
    if line.startsWith(expectPrefix):
      return line[expectPrefix.len .. ^1]
  ""

suite "test_cs_m9_combine_signature_checked":
  var fixtures: seq[string] = @[]
  for path in walkFiles(fixturesDir / "*.nim"):
    fixtures.add(path)

  test "the fixture set is not empty":
    check fixtures.len >= 1

  let scratch = createTempDir("confutils_cs_m9_", "")
  for fixture in fixtures:
    let caseName = fixture.splitFile().name
    test caseName:
      let text = readFile(fixture)
      let expected = expectedMessage(text)
      check expected.len > 0
      var kept: seq[string] = @[]
      var removed = 0
      for line in text.splitLines():
        if line.strip().endsWith(invalidMarker): inc removed
        else: kept.add(line)
      check removed == 1

      let invalidRun = nimCheck(fixture, scratch / caseName & "_invalid")
      check invalidRun.exitCode != 0
      check expected in invalidRun.output
      if invalidRun.exitCode == 0 or expected notin invalidRun.output:
        echo "  expected: ", expected
        echo "  compiler output:\n", invalidRun.output

      let validFile = scratch / (caseName & ".nim")
      writeFile(validFile, kept.join("\n"))
      let validRun = nimCheck(validFile, scratch / caseName & "_valid")
      check validRun.exitCode == 0
      if validRun.exitCode != 0:
        echo "  the fixture without its invalid line failed:\n",
          validRun.output
  removeDir(scratch)
