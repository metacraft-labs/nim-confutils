import os, strutils
mode = ScriptMode.Verbose

packageName   = "confutils"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Simplified handling of command line options and config files"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 2.0.0",
         "stew",
         "serialization"

# Clispec describes a command line declaratively and generates from it the
# configuration type, the argv parser, help and completion. Confutils can be
# instantiated over such a description (`confutils/clispec_config`) and adds
# configuration-file layers, the environment, merge rules and origins
# (`confutils/layers`). A program that reads TOML files through
# `confutils/layers/toml_source` requires `toml_serialization` itself. The
# pinned nim-cli-spec leaves configuration files to confutils, exports the
# generator helpers confutils uses (among them the value check its loader
# passes to the parser), can be required through Nimble, and has the opt-in
# rules that let a confutils type-based command line move onto a clispec
# description unchanged (among them `colonValues` and `equalsTakesNext`,
# with an unknown flag's error carrying the value written with it, so a
# program can word it as it did before, `rest` positionals, which stand
# for `{.restOfArgs.}` fields in the classic help confutils renders over a
# description, `confutils/clispec_classic_help`, and `loneDashesAreFlags`
# and `exactOneLetterFlags`, which read a lone `-` or `--` and one-letter
# option names as confutils' own parser does, `afterSeparator`
# positionals, which only the words after `--` fill, and `retired`
# spellings, refused with an error that names their replacement).
requires "https://github.com/metacraft-labs/nim-cli-spec#8c36bf19c98f551f8eaa03e9d12ecad387f3a081"

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
    run threads, "tests/clispec/test_clispec_all"

  # Compiles a fixture once per `-d:` case, so it runs in one configuration:
  # what it checks happens at compile time.
  build "-r", "tests/test_cs_m9b_compile_time_options"

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
