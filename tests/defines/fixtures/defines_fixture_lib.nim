# A library configured at compile time through `confutils/defines`.
# Built with only the checkout root on the path (`--path:<root>`); it imports
# only the two macros, which must not need anything else in scope.

from confutils/defines import enumDefine, flagDefine

type
  Level* = enum
    TRACE, DEBUG, INFO, NOTICE_LEVEL

  LineEndings* = enum
    windowsEndings = "windows"
    posixEndings = "posix"
    platformEndings = "platform"

  Colors* = enum
    NoColors, AnsiColors, NativeColors

const
  fixture_traces* {.flagDefine.} = false
  fixture_threads* {.flagDefine.}: bool = true
  fixture_level* {.enumDefine.}: Level = INFO
  fixture_endings* {.enumDefine.} = platformEndings
  fixtureColors* {.enumDefine("fixture.colors", offValue = NoColors).}: Colors =
    NativeColors
  fixtureFlag* {.flagDefine(name = "fixture.flag").} = false
