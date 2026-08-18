# nim-confutils
# Copyright (c) 2020-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Fixture application for `tests/test_known_limitations.nim`.
##
## It is a self-contained miniature of the shape that keeps running into
## the limitations catalogued in `docs/Limitations.md`:
##
## * a *pass-through* subcommand (`run`) whose first positional names another
##   program and whose trailing positional must carry that program's own argv
##   verbatim -- including dash-prefixed tokens;
## * a *command group* (`review`) with a default sub-command (`launch`, which
##   takes a positional) and a non-default sibling (`collect`).
##
## The fixture is compiled and executed as a subprocess by the tests that need
## to observe process-level behaviour: rendered `--help` text (which confutils
## writes straight to stdout before calling `quit`), and the runtime viability
## of a `{.command.}` discriminator under different `-d:nimOldCaseObjects`
## settings.
##
## `noCmdArgs {.ignore.}` is *not* decoration: an empty `of noCommand: discard`
## branch aborts the `configurationRtti` macro. That is limitation L8 -- see
## `tests/limitations/empty_command_branch.nim`.

import
  ../../confutils

type
  DemoCmd* = enum
    noCommand
    run
    review

  ReviewCmd* = enum
    launch
    collect

  DemoConf* = object
    cwd* {.
      defaultValue: ""
      desc: "Directory to operate in"
    .}: string

    deepreview* {.
      defaultValue: ""
      desc: "A parent-level option deliberately spelled like something a " &
            "recorded child program might also accept"
    .}: string

    case cmd* {.
      command
      defaultValue: noCommand
    .}: DemoCmd
    of noCommand:
      noCmdArgs* {.ignore.}: string

    of run:
      program* {.
        argument
        desc: "Program to run"
      .}: string

      progArgs* {.
        argument
        defaultValue: @[]
        desc: "Arguments forwarded to the program, verbatim"
      .}: seq[string]

    of review:
      case reviewCmd* {.
        command
        defaultValue: launch
      .}: ReviewCmd
      of launch:
        dataset* {.
          argument
          desc: "Dataset to open"
        .}: string
      of collect:
        repo* {.
          defaultValue: ""
          desc: "Repository to collect from"
        .}: string

when isMainModule:
  let conf = DemoConf.load()
  echo "cmd=", conf.cmd
  echo "cwd=", conf.cwd
  echo "deepreview=", conf.deepreview
  case conf.cmd
  of noCommand:
    discard
  of run:
    echo "program=", conf.program
    echo "progArgs=", conf.progArgs
  of review:
    echo "reviewCmd=", conf.reviewCmd
    case conf.reviewCmd
    of launch:
      echo "dataset=", conf.dataset
    of collect:
      echo "repo=", conf.repo
