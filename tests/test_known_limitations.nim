# nim-confutils
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Expected-red suite: the known limitations of confutils.
##
## **Every test in this file is expected to FAIL.** Each one asserts the
## behaviour confutils *should* have, so the suite is a machine-checkable
## restatement of `docs/Limitations.md` rather than a regression net. A green
## test here means a limitation has been fixed (or the test has drifted from
## the catalogue) -- either way, `docs/Limitations.md` must be updated in the
## same change, and the test moved into the ordinary suite.
##
## For that reason this file is deliberately **excluded** from
## `tests/test_all.nim` and from the default `nimble test` task. Run it with:
##
## ```
## nimble limitations
## ```
##
## Never "fix" a failure here by relaxing the assertion to match today's
## behaviour. A test that encodes the defect turns a defect into a
## specification.
##
## ## No mocks
##
## Per the workspace policy on mocking: this suite uses none. The in-process
## tests call the real `confutils.load` on a real configuration type; the
## subprocess tests invoke the real Nim compiler on real fixture sources and
## execute the real binaries it produces. The only indirection is that
## process-level behaviour (help text written straight to stdout before
## `quit`, and runtime aborts) can only be observed from a child process.

import
  std/[os, osproc, strutils, compilesettings],
  unittest2,
  ../confutils,
  ./limitations/pass_through_app

# ---------------------------------------------------------------------------
# In-process helpers
# ---------------------------------------------------------------------------

type
  LoadOutcome = object
    ## Result of a parse attempt: either a configuration or the diagnostic
    ## confutils refused it with. Modelled as data rather than as a raised
    ## exception so a test can assert on *either* half without the assertion
    ## itself being skipped by the throw.
    ok*: bool
    conf*: DemoConf
    error*: string

proc tryLoad(args: seq[string]): LoadOutcome =
  ## Parse `args` with the fixture configuration, capturing failure.
  ##
  ## `quitOnFailure = false` makes `load` raise instead of calling `quit`, and
  ## `printUsage = false` keeps the suite's output readable.
  try:
    LoadOutcome(
      ok: true,
      conf: DemoConf.load(
        cmdLine = args, quitOnFailure = false, printUsage = false))
  except ConfigurationError as err:
    LoadOutcome(ok: false, error: err.msg)

proc describe(outcome: LoadOutcome): string =
  ## A one-line rendering of an outcome, echoed on failure so the recorded
  ## test output shows what confutils actually did.
  if outcome.ok:
    "parsed: cmd=" & $outcome.conf.cmd &
      " cwd=" & outcome.conf.cwd.escape &
      " deepreview=" & outcome.conf.deepreview.escape &
      (if outcome.conf.cmd == run:
         " program=" & outcome.conf.program.escape &
           " progArgs=" & $outcome.conf.progArgs
       else: "")
  elif outcome.error.len > 0:
    "rejected: " & outcome.error
  else:
    "rejected, with an empty diagnostic (see L9)"

# ---------------------------------------------------------------------------
# Subprocess helpers
#
# Some of the behaviour under test is only observable outside the test
# process: `showHelp` writes to stdout and then calls `quit`, a configuration
# that fails `configurationRtti` cannot be imported at all, and a runtime
# `FieldDefect` aborts whichever process hits it.
# ---------------------------------------------------------------------------

const
  nimExe = getCurrentCompilerExe()
    ## The very compiler that built this test binary, so the fixtures are
    ## compiled by the same toolchain rather than by whatever `nim` PATH
    ## happens to resolve to.

  repoRoot = currentSourcePath().parentDir.parentDir
  fixtureDir = repoRoot / "tests" / "limitations"

  # The module search path this binary was compiled with, replayed onto the
  # fixture compilations so they resolve `confutils` and its dependencies
  # identically -- no nimble.paths guessing.
  inheritedSearchPaths = querySettingSeq(searchPaths)
  inheritedNimblePaths = querySettingSeq(nimblePaths)

type
  RunResult = object
    output*: string
    exitCode*: int

proc scratchDir(): string =
  result = getTempDir() / "confutils-known-limitations"
  createDir(result)

proc compileFixture(fixture: string, defines: seq[string] = @[]): RunResult =
  ## Compile `tests/limitations/<fixture>.nim` into the scratch directory.
  ##
  ## Returns the compiler's combined output and exit code instead of raising,
  ## because "did this configuration compile at all?" *is* the assertion for
  ## the compile-time limitations.
  let
    scratch = scratchDir()
    binPath = scratch / fixture & (when defined(windows): ".exe" else: "")
  var cmd = quoteShell(nimExe) & " c --hints:off --verbosity:0 --warnings:off" &
    " --nimcache:" & quoteShell(scratch / "nimcache" / fixture)
  for p in inheritedSearchPaths:
    cmd.add " --path:" & quoteShell(p)
  for p in inheritedNimblePaths:
    cmd.add " --path:" & quoteShell(p)
  for d in defines:
    cmd.add " -d:" & d
  cmd.add " -o:" & quoteShell(binPath)
  cmd.add " " & quoteShell(fixtureDir / fixture & ".nim")

  let (output, exitCode) = execCmdEx(cmd)
  RunResult(output: output, exitCode: exitCode)

proc runFixture(fixture: string, args: seq[string]): RunResult =
  ## Execute an already-compiled fixture binary with `args`.
  let binPath = scratchDir() / fixture & (when defined(windows): ".exe" else: "")
  var cmd = quoteShell(binPath)
  for a in args:
    cmd.add " " & quoteShell(a)
  let (output, exitCode) = execCmdEx(cmd)
  RunResult(output: output, exitCode: exitCode)

func stripAnsi(s: string): string =
  ## Drop SGR escape sequences so help-text assertions are about the text.
  ## confutils colours its output unconditionally when built without
  ## `-d:confutils_no_colors`.
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'m', 'K'}:
        inc i
      inc i
    else:
      result.add s[i]
      inc i

# ---------------------------------------------------------------------------

suite "confutils known limitations (expected-red)":

  test "L1 a pass-through subcommand forwards dash-prefixed arguments":
    # `run` names another program; that program's flags are not ours.
    # confutils must leave them alone and hand them to the trailing
    # `seq[string]` positional.
    let outcome = tryLoad(@["run", "php", "-S", "localhost:8000", "-t", "public/"])
    echo "  actual -> ", outcome.describe
    check outcome.ok
    if outcome.ok:
      check outcome.conf.program == "php"
      check outcome.conf.progArgs == @["-S", "localhost:8000", "-t", "public/"]

  test "L2 the POSIX -- separator ends option parsing":
    # Everything to the right of a bare `--` is data, per POSIX Utility
    # Syntax Guideline 10. It must not be matched against any option of any
    # command in the active stack.
    let outcome = tryLoad(@["run", "./prog", "--", "--deepreview", "x"])
    echo "  actual -> ", outcome.describe
    check outcome.ok
    if outcome.ok:
      check outcome.conf.deepreview == ""
      check outcome.conf.program == "./prog"
      check outcome.conf.progArgs == @["--deepreview", "x"]

  test "L3 a parent option is not claimed after a subcommand's positionals":
    # `--cwd` precedes the subcommand, so it is ours. `--deepreview` appears
    # after `run`'s positional has started collecting, so it belongs to the
    # collecting positional -- exactly as `{.restOfArgs.}` already treats it.
    # Claiming it for the parent silently changes the meaning of the line.
    let outcome = tryLoad(
      @["--cwd", "/tmp", "run", "./prog", "--deepreview", "x"])
    echo "  actual -> ", outcome.describe
    check outcome.ok
    if outcome.ok:
      check outcome.conf.cwd == "/tmp"
      check outcome.conf.program == "./prog"
      check outcome.conf.deepreview == ""
      check outcome.conf.progArgs == @["--deepreview", "x"]

  test "L4 restOfArgs may coexist with an option in the same command":
    # A pass-through subcommand almost always has at least one flag of its
    # own. `restOfArgs` is the only construct that forwards dash-prefixed
    # tokens, so refusing the combination refuses the use case.
    let build = compileFixture("restofargs_with_flag",
                               defines = @["nimOldCaseObjects"])
    if build.exitCode != 0:
      echo "  compiler said:\n", build.output.strip.indent(4)
    check build.exitCode == 0

  test "L5 group help shows the default sub-command's own invocation":
    # `<app> review --help` must document every form of `review`, including
    # the default sub-command's positional signature. A user who asks a
    # command for help should learn everything the command can do.
    let build = compileFixture("pass_through_app",
                               defines = @["nimOldCaseObjects"])
    require build.exitCode == 0
    let help = runFixture("pass_through_app", @["review", "--help"])
    echo "  actual help:\n", help.output.stripAnsi.strip.indent(4)
    let text = help.output.stripAnsi
    check "review <dataset>" in text   # the default sub-command's form
    check "collect" in text            # the sibling (already listed today)

  test "L6 usage and errors name the running program":
    # `appInvocation` is hard-coded to "ct" in this fork, so every consumer is
    # told to run CodeTracer. The diagnostic must name the actual binary.
    #
    # Observed from a subprocess because the text only exists on the
    # process-terminating path -- see L9.
    let build = compileFixture("pass_through_app",
                               defines = @["nimOldCaseObjects"])
    require build.exitCode == 0
    let bogus = runFixture("pass_through_app", @["definitely-not-a-subcommand"])
    echo "  actual -> ", bogus.output.stripAnsi.strip.escape
    let text = bogus.output.stripAnsi
    check "pass_through_app" in text
    check "ct has no such subcommand" notin text

  test "L7 a command discriminator works without -d:nimOldCaseObjects":
    # confutils assigns the `{.command.}` discriminator in place, which Nim
    # has rejected since 0.20 unless the deprecated transition define is set.
    # Every downstream program is forced to carry that define.
    let build = compileFixture("pass_through_app")
    require build.exitCode == 0
    let run = runFixture("pass_through_app", @["run", "./prog"])
    if run.exitCode != 0:
      echo "  actual:\n", run.output.strip.indent(4)
    check run.exitCode == 0
    check "program=./prog" in run.output

  test "L8 a one-line field-less command branch compiles":
    # `of noCommand: discard` is the natural spelling of "this command takes
    # nothing". Written on two lines it compiles; written on one it aborts the
    # macro with an internal AssertionDefect. Layout must not decide this.
    let build = compileFixture("empty_command_branch",
                               defines = @["nimOldCaseObjects"])
    if build.exitCode != 0:
      echo "  compiler said:\n", build.output.strip.indent(4)
    check build.exitCode == 0

  test "L9 a rejected command line raises a diagnostic, not an empty error":
    # With `quitOnFailure = false` the caller takes responsibility for
    # reporting the failure -- so the failure has to reach the caller.
    # Today the message is produced only on the path that also calls `quit`,
    # and the raised `ConfigurationError` carries an empty string
    # (`# TODO: populate this string`, confutils.nim `fail`). An embedding
    # application therefore cannot tell the user what was wrong.
    let outcome = tryLoad(@["run", "php", "-S", "localhost:8000"])
    echo "  actual -> ", outcome.describe
    require not outcome.ok
    check outcome.error.len > 0
    check "-S" in outcome.error or "'S'" in outcome.error
