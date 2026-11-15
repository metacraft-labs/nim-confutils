## For ``test_cs_m10_classic_help``: prints a help screen the way a program
## does, so the test can compare what reaches stdout. ``confutils <words>``
## is ``FixConf.load`` of ``<words> --help``, which prints confutils' own
## help and quits; ``classic <words>`` is ``FixSpec.showClassicHelp`` of the
## same command. Both take the width from the terminal (``COLUMNS``).
## The test compiles it with and without ``-d:confutils_no_colors``.

import std/os
import ./classic_help_conf, ./classic_help_spec

let args = commandLineParams()
if args.len >= 1 and args[0] == "confutils":
  discard FixConf.load(cmdLine = args[1 .. ^1] & @["--help"],
                       copyrightBanner = banner)
  quit "not reached: --help quits", 3
elif args.len >= 1 and args[0] == "classic":
  # The fork's confutils names the program `ct` in help.
  FixSpec.showClassicHelp(args[1 .. ^1], programName = "ct",
                          copyrightBanner = banner)
else:
  quit "usage: classic_help_probe confutils|classic <words>", 2
