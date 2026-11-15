## A confutils configuration type, for ``test_cs_m10_classic_help``: the
## type ``classic_help_spec`` describes in clispec. It has enum subcommands
## (a default one, a nested discriminator), abbreviations (one letter and
## multi-character), defaults of several types (``bool``, ``string``,
## ``seq``, an enum, ``int``, ``float``) and a ``defaultValueDesc``,
## ``longDesc``, positionals that end their command and one that does not,
## an ``Option[bool]``, a ``restOfArgs`` field, a hidden field and an
## ignored one.

import ../../confutils
import ./classic_help_types

export confutils, classic_help_types

type
  FixCommand* = enum
    noCommand
    build
    print
    run
    remote
    plain = "A plain command"

  RemoteCommand* = enum
    noCommand
    push
    pull

  FixConf* = object
    verbose* {.abbr: "v", desc: "Print more about what is done",
               defaultValue: false.}: bool
    logLevel* {.name: "log-level", desc: "The log level, a %t",
                defaultValue: "info".}: string
    tags* {.desc: "Tags to apply to every result; can be given several " &
                  "times, each one adding a tag",
            defaultValue: @[].}: seq[string]
    quiet* {.abbr: "qq", desc: "Print less", defaultValue: false.}: bool
    cacheDir* {.name: "cache-dir", desc: "Where results are cached",
                longDesc: "Created when missing.\nNever cleaned up by " &
                  "this program, so remove it by hand when it grows " &
                  "too large for the disk it is on.",
                defaultValue: "/tmp/fix-cache",
                defaultValueDesc: "$HOME/.cache/fix".}: string
    secretToken* {.hidden, name: "secret-token-for-the-service",
                   desc: "Not listed", defaultValue: "".}: string
    internalState* {.ignore.}: int

    case cmd* {.command, defaultValue: FixCommand.noCommand.}: FixCommand
    of FixCommand.noCommand:
      interactive* {.abbr: "i",
                     desc: "Choose the input interactively".}: Option[bool]
    of FixCommand.build:
      mode* {.desc: "Build mode", defaultValue: Mode.fast.}: Mode
      jobs* {.abbr: "j", desc: "Parallel jobs", defaultValue: 4.}: int
      remoteDebuggingPortNumber* {.name: "remote-debugging-port-number",
        desc: "The port a debugger attaches to; a name longer than the " &
              "name column, which confutils does not pad",
        defaultValue: 0.}: int
      ratio* {.desc: "Share of the cache to keep",
               defaultValue: 0.5.}: float
      target* {.argument, desc: "What to build".}: string
      extra* {.argument, desc: "Words passed to the build",
               longDesc: "Passed through unchanged, flags included.",
               defaultValue: @[].}: seq[string]
    of FixCommand.print:
      printPath* {.argument, desc: "Path to print".}: string
      printFilter* {.name: "filter", abbr: "f",
                     desc: "Only events of this kind".}: Option[string]
      printFollow* {.name: "follow", abbr: "F",
                     desc: "Keep printing new events as they arrive " &
                           "(like tail -f)",
                     defaultValue: false.}: bool
    of FixCommand.run:
      runProgram* {.argument, desc: "Program to run".}: string
      runArgs* {.restOfArgs, desc: "Its arguments".}: seq[string]
    of FixCommand.remote:
      server* {.desc: "Server to talk to", defaultValue: "localhost".}: string
      case remoteCmd* {.command,
                        defaultValue: RemoteCommand.noCommand.}: RemoteCommand
      of RemoteCommand.noCommand:
        discard
      of RemoteCommand.push:
        pushRef* {.argument, desc: "The ref to push".}: string
      of RemoteCommand.pull:
        pullForce* {.name: "force", abbr: "f",
                     desc: "Overwrite local changes",
                     defaultValue: false.}: bool
    of FixCommand.plain:
      discard
