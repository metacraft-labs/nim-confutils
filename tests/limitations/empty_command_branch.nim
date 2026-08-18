# nim-confutils
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Compile probe for limitation L8 of `docs/Limitations.md`:
## a field-less command branch written on one line aborts the configuration
## macro.
##
## The branch below is
##
## ```nim
##     of noCommand: discard
## ```
##
## Writing the *same* branch across two lines --
##
## ```nim
##     of noCommand:
##       discard
## ```
##
## -- compiles and behaves identically. Nim spells the one-line form as an
## `nnkOfBranch` holding an `nnkNilLit`, and confutils' `generateSecondarySources`
## walks that tree without a case for it, so the macro dies with a raw
## `AssertionDefect` whose stack trace points into `system/fatal.nim` rather
## than at the offending declaration. Nothing tells the author that
## reformatting the branch is the cure.
##
## This file is expected to COMPILE. It does not today.

import
  ../../confutils

type
  PlainCmd = enum
    noCommand
    greet

  PlainConf = object
    verbose {.
      defaultValue: false
      desc: "Verbose output"
    .}: bool

    case cmd {.
      command
      defaultValue: noCommand
    .}: PlainCmd
    of noCommand: discard

    of greet:
      who {.
        argument
        desc: "Who to greet"
      .}: string

when isMainModule:
  let conf = PlainConf.load(
    cmdLine = @["greet", "world"],
    quitOnFailure = false,
    printUsage = false)
  echo "who=", conf.who
