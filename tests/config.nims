# nim-confutils, `codetracer` branch: the dependency set the tests build against.
#
# This fork is consumed as codetracer's `libs/nim-confutils` submodule, and
# codetracer pins every library it compiles confutils with in sibling `libs/`
# submodules. Its tests must build against those revisions, not against
# whatever happens to be installed in `~/.nimble`: a newer `stew` there lacks
# `stew/shims/net`, and an unpinned `toml_serialization` does not build against
# the 2022 `serialization` codetracer pins. The test-only dependencies
# (`toml_serialization`, `unittest2`) are pinned there too, at revisions
# compatible with that stack.
#
# Outside a codetracer checkout none of these directories exist and nothing
# is changed: the tests resolve their dependencies through Nimble as upstream's
# do.

import std/os

const codetracerLibs = currentSourcePath().parentDir.parentDir.parentDir

const pinnedLibs = [
  "nim-stew",
  "nim-serialization",
  "nim-json-serialization",
  "nim-faststreams",
  "nim-result",
  "nim-toml-serialization",
  "nim-unittest2",
]

# A codetracer checkout has a `libs/nim-serialization` directory even when that
# submodule is not initialised (git leaves an empty directory), so test for the
# directory: an uninitialised submodule then gets the message below instead of
# a silent fallback to `~/.nimble`.
if dirExists(codetracerLibs / "nim-serialization"):
  # The --path entries below are searched before Nimble's packages, but a
  # package left off this list would still resolve from `~/.nimble`, and the
  # build would then depend on the host. Turning Nimble off makes an omission
  # fail to compile instead.
  switch("noNimblePath")
  for lib in pinnedLibs:
    let dir = codetracerLibs / lib
    # An uninitialised submodule is an empty directory: treat it as missing.
    if dirExists(dir) and listFiles(dir).len > 0:
      switch("path", dir)
    else:
      quit("tests/config.nims: codetracer checkout without " & dir &
           "; run `git submodule update --init libs/" & lib & "`")
