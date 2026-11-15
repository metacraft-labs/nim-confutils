## The clispec description of ``classic_help_conf``'s ``FixConf``, for
## ``test_cs_m10_classic_help``: the same parameters in the same order,
## each with what its field declares (``confutils/clispec_classic_help``,
## "The equivalent type"). The ignored field is not declared.

import ../../confutils/clispec_config
import std/options
import ./classic_help_types

export options, clispec_config, classic_help_types

cliConfiguration(FixSpec, "fix", exported = true):
  boolFlag verbose is bool, short = 'v', default = false,
    help = "Print more about what is done"
  flag logLevel is string, perSource = [cli = "log-level"], default = "info",
    help = "The log level, a %t"
  flag tags is seq[string], default = @[],
    help = "Tags to apply to every result; can be given several " &
           "times, each one adding a tag"
  boolFlag quiet is bool, alias = "--qq", default = false, help = "Print less"
  flag cacheDir is string, perSource = [cli = "cache-dir"],
    help = "Where results are cached",
    longHelp = "Created when missing.\nNever cleaned up by " &
      "this program, so remove it by hand when it grows " &
      "too large for the disk it is on.",
    default = "/tmp/fix-cache", defaultValueDesc = "$HOME/.cache/fix"
  flag secretToken is string, visibility = hidden,
    perSource = [cli = "secret-token-for-the-service"],
    help = "Not listed", default = ""
  call:
    flag interactive is Option[bool], short = 'i',
      help = "Choose the input interactively"
  subcmd "build":
    flag mode is Mode, default = Mode.fast, help = "Build mode"
    flag jobs is int, short = 'j', default = 4, help = "Parallel jobs"
    flag remoteDebuggingPortNumber is int,
      perSource = [cli = "remote-debugging-port-number"],
      help = "The port a debugger attaches to; a name longer than the " &
             "name column, which confutils does not pad",
      default = 0
    flag ratio is float, default = 0.5, help = "Share of the cache to keep"
    pos target is string, help = "What to build"
    pos extra is seq[string], repeated = true, default = @[],
      help = "Words passed to the build",
      longHelp = "Passed through unchanged, flags included."
  subcmd "print":
    pos printPath is string, help = "Path to print"
    flag printFilter is Option[string], short = 'f',
      perSource = [cli = "filter"], help = "Only events of this kind"
    boolFlag printFollow is bool, short = 'F', perSource = [cli = "follow"],
      default = false,
      help = "Keep printing new events as they arrive (like tail -f)"
  subcmd "run":
    pos runProgram is string, help = "Program to run"
    pos runArgs is seq[string], rest = true, required = false,
      help = "Its arguments"
  subcmd "remote":
    flag server is string, default = "localhost", help = "Server to talk to"
    call:
      discard
    subcmd "push":
      pos pushRef is string, help = "The ref to push"
    subcmd "pull":
      boolFlag pullForce is bool, short = 'f', perSource = [cli = "force"],
        default = false, help = "Overwrite local changes"
  subcmd "plain", help = "A plain command":
    discard
