import os, strutils
mode = ScriptMode.Verbose

packageName   = "confutils"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Simplified handling of command line options and config files"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.6.0",
         "stew",
         "serialization"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

task test, "Run all tests":
  for threads in ["--threads:off", "--threads:on"]:
    run threads, "tests/test_all"
    build threads, "tests/test_duplicates"

  #Also iterate over every test in tests/fail, and verify they fail to compile.
  echo "\r\nTest Fail to Compile:"
  for path in listFiles(thisDir() / "tests" / "fail"):
    if path.split(".")[^1] != "nim":
      continue

    if gorgeEx(nimc & " " & lang & " " & flags & " " & path).exitCode != 0:
      echo "  [OK] ", path.split(DirSep)[^1]
    else:
      echo "  [FAILED] ", path.split(DirSep)[^1]
      quit(QuitFailure)

task limitations, "Run the EXPECTED-RED known-limitations suite (docs/Limitations.md)":
  # `tests/test_known_limitations.nim` asserts the behaviour confutils SHOULD
  # have, so every test in it fails today and this task exits non-zero by
  # design. That is why it is not part of `test` above and why the file is not
  # imported by `tests/test_all.nim`: the ordinary suite must stay green.
  #
  # A GREEN run means a limitation was fixed (or a test drifted). Either way,
  # update docs/Limitations.md in the same change and move the test into the
  # ordinary suite -- do NOT relax an assertion to match today's behaviour.
  #
  # `-d:nimOldCaseObjects` is itself limitation L7: without it a configuration
  # with a `{.command.}` discriminator aborts at runtime. The suite carries it
  # so the other eight limitations can be reached, and compiles a fixture
  # *without* it to demonstrate L7.
  echo "\r\nEXPECTED-RED: every test below asserts behaviour confutils does " &
       "not have yet.\r\nSee docs/Limitations.md.\r\n"
  build " --threads:off -d:nimOldCaseObjects -r", "tests/test_known_limitations"
