# nim-confutils
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Compile probe for limitation L4 of `docs/Limitations.md`:
## `{.restOfArgs.}` may not be combined with a CLI switch in the same command.
##
## `{.restOfArgs.}` is the only construct in confutils that forwards
## dash-prefixed tokens verbatim, so it is precisely the construct a
## pass-through subcommand needs -- but the moment that subcommand also
## declares one ordinary option, `configurationRtti` refuses the whole
## configuration at compile time.
##
## This file is expected to COMPILE. It does not today.
## `tests/test_known_limitations.nim` compiles it as a subprocess and asserts
## success; it is never imported into a test binary, because a compile-time
## `error()` cannot be caught from the importing module.

import
  std/strutils,
  ../../confutils

type
  ExecCmd = enum
    noCommand
    exec

  ExecConf = object
    case cmd {.
      command
      defaultValue: noCommand
    .}: ExecCmd
    of noCommand:
      noCmdArgs {.ignore.}: string

    of exec:
      quiet {.
        defaultValue: false
        desc: "Suppress progress output"
      .}: bool

      program {.
        argument
        desc: "Program to execute"
      .}: string

      rest {.
        restOfArgs
        defaultValue: @[]
        desc: "Arguments forwarded to the program, verbatim"
      .}: seq[string]

when isMainModule:
  let conf = ExecConf.load(
    cmdLine = @["exec", "php", "-S", "localhost:8000"],
    quitOnFailure = false,
    printUsage = false)
  echo "quiet=", conf.quiet
  echo "program=", conf.program
  echo "rest=", conf.rest.join("|")
