# nim-confutils, `codetracer` branch: the dependency set the clispec tests
# build against.
#
# The tests are compiled with `--skipParentCfg`, so `tests/config.nims` does
# not apply here; this file includes it, so inside a codetracer checkout these
# tests too build against the revisions codetracer pins in its `libs/`
# submodules, with Nimble turned off. They also need nim-cli-spec, which
# `confutils/clispec_config` is built on: codetracer must carry it as
# `libs/nim-cli-spec`, and without it the build stops here with a message
# saying so, rather than failing on a missing `clispec` module or resolving
# it from `~/.nimble`.
#
# `test_cs_m9_combine_signature_checked` runs the compiler on fixtures that
# no configuration file covers, so the same paths reach it as the define
# `confutilsTestPaths` (`|`-separated), which it turns into `--noNimblePath`
# and `--path` flags.
#
# Outside a codetracer checkout nothing is changed: the tests resolve their
# dependencies through Nimble.

include "../config.nims"

import std/strutils

if dirExists(codetracerLibs / "nim-serialization"):
  let cliSpec = codetracerLibs / "nim-cli-spec"
  if fileExists(cliSpec / "src" / "clispec.nim"):
    switch("path", cliSpec / "src")
    var paths = @[cliSpec / "src"]
    for lib in pinnedLibs:
      paths.add(codetracerLibs / lib)
    switch("define", "confutilsTestPaths=" & paths.join("|"))
  else:
    quit("tests/clispec/config.nims: codetracer checkout without " & cliSpec &
         "; the clispec tests need nim-cli-spec there (add it as the " &
         "submodule libs/nim-cli-spec, or `git submodule update --init " &
         "libs/nim-cli-spec`)")
