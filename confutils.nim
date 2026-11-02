import
  os,
  std/[enumutils, options, strutils, wordwrap, strformat, sequtils],
  serialization,
  confutils/[defs, cli_parser, config_file, runtime_surface]
import stew/shims/macros except readPragma

# `stew` deprecated `readPragma` in 0.6.4 and removed it after that.  This is
# the same lookup, kept here so that confutils builds against both: it returns
# the pragma's single argument, the whole pragma node otherwise, or nil.
template readPragma(field: FieldDescription, pragmaName: static string): NimNode =
  let p = findPragma(field.pragmas, bindSym(pragmaName))
  if p != nil and p.len == 2: p[1] else: p

export
  options, serialization, defs, config_file, runtime_surface

const
  useBufferedOutput = defined(nimscript)
  noColors = useBufferedOutput or defined(confutils_no_colors)
  hasCompletions = not defined(nimscript)
  descPadding = 6
  minNameWidth =  24 - descPadding

when not defined(nimscript):
  import
    os, terminal,
    confutils/shell_completion

type
  HelpAppInfo = ref object
    appInvocation: string
    copyrightBanner: string
    hasAbbrs: bool
    maxNameLen: int
    terminalWidth: int
    namesWidth: int

  CmdInfo = ref object
    name: string
    desc: string
    isHidden: bool
    hasRestOfArgs: bool
    opts: seq[OptInfo]

  OptKind = enum
    Discriminator
    CliSwitch
    Arg
    RestOfArgs

  OptInfo = ref object
    name, abbr, desc, typename: string
    separator: string
    longDesc: string
    idx: int
    isHidden: bool
    hasDefault: bool
    defaultInHelpText: string
    hasImplicitValue: bool    # `{.implicitValue.}`: the value may be omitted
    implicitValue: string
    alsoSetsIdx: int          # `{.alsoSets.}` target field index, or -1
    alsoSetsValue: string
    valueName: string         # `{.valueName.}`: the help placeholder
    case kind: OptKind
    of Discriminator:
      isCommand: bool
      isImplicitlySelectable: bool
      subCmds: seq[CmdInfo]
      defaultSubCmd: int
    of RestOfArgs:
      requiredArgsCount: int
    else:
      discard

const
  confutils_description_width {.intdefine.} = 80
  confutils_narrow_terminal_width {.intdefine.} = 36

func getFieldName(caseField: NimNode): NimNode =
  result = caseField
  if result.kind == nnkIdentDefs: result = result[0]
  if result.kind == nnkPragmaExpr: result = result[0]
  if result.kind == nnkPostfix: result = result[1]

when defined(nimscript):
  func scriptNameParamIdx: int =
    for i in 1 ..< paramCount():
      var param = paramStr(i)
      if param.len > 0 and param[0] != '-':
        return i

  proc appInvocation: string =
    let scriptNameIdx = scriptNameParamIdx()
    "nim " & (if paramCount() > scriptNameIdx: paramStr(scriptNameIdx) else: "<nims-script>")

  type stderr = object

  template writeLine(T: type stderr, msg: string) =
    echo msg

  proc commandLineParams(): seq[string] =
    for i in scriptNameParamIdx() + 1 .. paramCount():
      result.add paramStr(i)

  # TODO: Why isn't this available in NimScript?
  proc getCurrentExceptionMsg(): string =
    ""

  template terminalWidth: int =
    100000

else:
  template appInvocation: string = "ct"

when noColors:
  const
    styleBright = ""
    fgYellow = ""
    fgWhite = ""
    fgGreen = ""
    fgCyan = ""
    fgBlue = ""
    resetStyle = ""

when useBufferedOutput:
  template helpOutput(args: varargs[string]) =
    for arg in args:
      help.add arg

  template errorOutput(args: varargs[string]) =
    helpOutput(args)

  template flushOutput =
    echo help

else:
  template errorOutput(args: varargs[untyped]) =
    try:
      styledWrite stderr, args
    except IOError, ValueError:
      discard

  template helpOutput(args: varargs[untyped]) =
    try:
      styledWrite stdout, args
    except IOError, ValueError:
      discard

  template flushOutput =
    discard

const
  fgSection = fgYellow
  fgDefault = fgWhite
  fgCommand = fgCyan
  fgOption = fgBlue
  fgArg = fgBlue

  # TODO: Start using these:
  # fgValue = fgGreen
  # fgType = fgYellow

template flushOutputAndQuit(exitCode: int) =
  flushOutput
  quit exitCode

func isCliSwitch(opt: OptInfo): bool =
  opt.kind == CliSwitch or
  (opt.kind == Discriminator and opt.isCommand == false)

func hasOpts(cmd: CmdInfo): bool =
  for opt in cmd.opts:
    if opt.isCliSwitch and not opt.isHidden:
      return true

  return false

func hasArgs(cmd: CmdInfo): bool =
  cmd.opts.len > 0 and cmd.opts[^1].kind == Arg

func hasAnyArgs(cmd: CmdInfo): bool =
  cmd.opts.len > 0 and cmd.opts.anyIt(it.kind == Arg)

func firstArgIdx(cmd: CmdInfo): int =
  # This will work correctly only if the command has arguments.
  result = cmd.opts.len - 1
  while result > 0:
    if cmd.opts[result - 1].kind != Arg:
      return
    dec result

iterator args(cmd: CmdInfo): OptInfo =
  if cmd.hasArgs:
    for i in cmd.firstArgIdx ..< cmd.opts.len:
      yield cmd.opts[i]

func getSubCmdDiscriminator(cmd: CmdInfo): OptInfo =
  for i in countdown(cmd.opts.len - 1, 0):
    let opt = cmd.opts[i]
    if opt.kind != Arg:
      if opt.kind == Discriminator and opt.isCommand:
        return opt
      else:
        return nil

template hasSubCommands(cmd: CmdInfo): bool =
  getSubCmdDiscriminator(cmd) != nil

iterator subCmds(cmd: CmdInfo): CmdInfo =
  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    for cmd in subCmdDiscriminator.subCmds:
      yield cmd

template isSubCommand(cmd: CmdInfo): bool =
  cmd.name.len > 0

func maxNameLen(cmd: CmdInfo): int =
  result = 0
  for opt in cmd.opts:
    if opt.kind == Arg or opt.kind == Discriminator and opt.isCommand:
      continue
    result = max(result, opt.name.len)
    if opt.kind == Discriminator:
      for subCmd in opt.subCmds:
        result = max(result, subCmd.maxNameLen)

func hasAbbrs(cmd: CmdInfo): bool =
  for opt in cmd.opts:
    if opt.kind == Arg or opt.kind == Discriminator and opt.isCommand:
      continue
    if opt.abbr.len > 0:
      return true
    if opt.kind == Discriminator:
      for subCmd in opt.subCmds:
        if hasAbbrs(subCmd):
          return true

func humaneName(opt: OptInfo): string =
  if opt.name.len > 0: opt.name
  else: opt.abbr

template padding(output: string, desiredWidth: int): string =
  spaces(max(desiredWidth - output.len, 0))

proc writeDesc(help: var string,
               appInfo: HelpAppInfo,
               desc, defaultValue: string) =
  const descSpacing = "  "
  let
    descIndent = (5 + appInfo.namesWidth + descSpacing.len)
    remainingColumns = appInfo.terminalWidth - descIndent
    defaultValSuffix = if defaultValue.len == 0: ""
                       else: " [=" & defaultValue & "]"
    fullDesc = desc & defaultValSuffix & "."

  if remainingColumns < confutils_narrow_terminal_width:
    helpOutput "\p ", wrapWords(fullDesc, appInfo.terminalWidth - 2,
                                newLine = "\p ")
  else:
    let wrappingWidth = min(remainingColumns, confutils_description_width)
    helpOutput descSpacing, wrapWords(fullDesc, wrappingWidth,
                                      newLine = "\p" & spaces(descIndent))

proc writeLongDesc(help: var string,
               appInfo: HelpAppInfo,
               desc: string) =
  let lines = split(desc, {'\n', '\r'})
  for line in lines:
    if line.len > 0:
      helpOutput "\p"
      helpOutput padding("", 5 + appInfo.namesWidth)
      help.writeDesc appInfo, line, ""

proc describeInvocation(help: var string,
                        cmd: CmdInfo, cmdInvocation: string,
                        appInfo: HelpAppInfo) =
  helpOutput styleBright, "\p", fgCommand, cmdInvocation
  var longestArg = 0

  if cmd.opts.len > 0:
    if cmd.hasOpts: helpOutput " [OPTIONS]..."

    let subCmdDiscriminator = cmd.getSubCmdDiscriminator
    if subCmdDiscriminator != nil: helpOutput " command"

    for arg in cmd.args:
      helpOutput " <", arg.name, ">"
      longestArg = max(longestArg, arg.name.len)

  helpOutput "\p"

  if cmd.desc.len > 0:
    helpOutput "\p", cmd.desc, ".\p"

  var argsSectionStarted = false

  for arg in cmd.args:
    if arg.desc.len > 0:
      if not argsSectionStarted:
        helpOutput "\p"
        argsSectionStarted = true

      let cliArg = " <" & arg.humaneName & ">"
      helpOutput fgArg, styleBright, cliArg
      helpOutput padding(cliArg, 6 + appInfo.namesWidth)
      help.writeDesc appInfo, arg.desc, arg.defaultInHelpText
      help.writeLongDesc appInfo, arg.longDesc
      helpOutput "\p"

type
  OptionsType = enum
    normalOpts
    defaultCmdOpts
    conditionalOpts

proc describeOptions(help: var string,
                     cmd: CmdInfo, cmdInvocation: string,
                     appInfo: HelpAppInfo, optionsType = normalOpts) =
  if cmd.hasOpts:
    case optionsType
    of normalOpts:
      helpOutput "\pThe following options are available:\p\p"
    of conditionalOpts:
      helpOutput ", the following additional options are available:\p\p"
    of defaultCmdOpts:
      discard

    for opt in cmd.opts:
      if opt.kind == Arg or
         opt.kind == Discriminator or
         opt.isHidden: continue

      if opt.separator.len > 0:
        helpOutput opt.separator
        helpOutput "\p"

      # Indent all command-line switches
      helpOutput " "

      if opt.abbr.len > 0:
        # A multi-character abbreviation is matched as a LONG switch
        # (`findOpt` compares it with the key of `--abbr`), so show it so.
        let abbrDashes = if opt.abbr.len > 1: "--" else: "-"
        helpOutput fgOption, styleBright, abbrDashes, opt.abbr, ", "
      elif appInfo.hasAbbrs:
        # Add additional indentatition, so all names are aligned
        helpOutput "    "

      if opt.name.len > 0:
        let switch = "--" & opt.name
        helpOutput fgOption, styleBright,
                   switch, padding(switch, appInfo.namesWidth)
      else:
        helpOutput spaces(2 + appInfo.namesWidth)

      if opt.desc.len > 0:
        help.writeDesc appInfo,
                       opt.desc.replace("%t", opt.typename),
                       opt.defaultInHelpText
        help.writeLongDesc appInfo, opt.longDesc

      helpOutput "\p"

      if opt.kind == Discriminator:
        for i, subCmd in opt.subCmds:
          if not subCmd.hasOpts: continue

          helpOutput "\pWhen ", styleBright, fgBlue, opt.humaneName, resetStyle, " = ", fgGreen, subCmd.name

          if i == opt.defaultSubCmd: helpOutput " (default)"
          help.describeOptions subCmd, cmdInvocation, appInfo, conditionalOpts

  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    let defaultCmdIdx = subCmdDiscriminator.defaultSubCmd
    if defaultCmdIdx != -1:
      let defaultCmd = subCmdDiscriminator.subCmds[defaultCmdIdx]
      help.describeOptions defaultCmd, cmdInvocation, appInfo, defaultCmdOpts

    helpOutput fgSection, "\pAvailable sub-commands:\p"

    for i, subCmd in subCmdDiscriminator.subCmds:
      if i != subCmdDiscriminator.defaultSubCmd:
        let subCmdInvocation = cmdInvocation & " " & subCmd.name
        help.describeInvocation subCmd, subCmdInvocation, appInfo
        help.describeOptions subCmd, subCmdInvocation, appInfo

proc showHelp(help: var string,
              appInfo: HelpAppInfo,
              activeCmds: openArray[CmdInfo]) =
  if appInfo.copyrightBanner.len > 0:
    helpOutput appInfo.copyrightBanner, "\p\p"

  let cmd = activeCmds[^1]

  appInfo.maxNameLen = cmd.maxNameLen
  appInfo.hasAbbrs = cmd.hasAbbrs
  appInfo.terminalWidth =
    try:
      terminalWidth()
    except ValueError:
      int.high  # https://github.com/nim-lang/Nim/pull/21968
  appInfo.namesWidth = min(minNameWidth, appInfo.maxNameLen) + descPadding

  var cmdInvocation = appInfo.appInvocation
  for i in 1 ..< activeCmds.len:
    cmdInvocation.add " "
    cmdInvocation.add activeCmds[i].name

  # Write out the app or script name
  helpOutput fgSection, "Usage: \p"
  help.describeInvocation cmd, cmdInvocation, appInfo
  help.describeOptions cmd, cmdInvocation, appInfo
  helpOutput "\p"

  flushOutputAndQuit QuitSuccess

func getNextArgIdx(cmd: CmdInfo, consumedArgIdx: int): int =
  for i in 0 ..< cmd.opts.len:
    if (cmd.opts[i].kind == Arg or cmd.opts[i].kind == RestOfArgs) and cmd.opts[i].idx > consumedArgIdx:
      return cmd.opts[i].idx

  -1

proc noMoreArgsError(cmd: CmdInfo): string {.raises: [].} =
  result =
    if cmd.isSubCommand:
      try:
        "The subcommand '$1'" % [cmd.name]
      except ValueError as err:
        raiseAssert "strutils.`%` failed: " & err.msg
    else:
      appInvocation()
  result.add " does not accept"
  if cmd.hasAnyArgs: result.add " additional"
  result.add " arguments"

  if not cmd.hasAnyArgs and not cmd.isSubCommand:
    result = appInvocation() & " has no such subcommand"
  
func isSwitch(opt: OptInfo): bool =
  ## Whether `opt` is a switch: on when given, off when omitted, and never
  ## given its value by the next token (`--flag=false` still sets one).  A
  ## `bool` field is one, and so is an `Option[bool]` field, whose only
  ## difference is that "not given" stays observable as `none`.  Treating
  ## `Option[bool]` as value-taking made `--flag <positional>` spend the
  ## positional argument as the switch's value.
  ##
  ## `typename` is the field type's `repr`, so the qualified spellings are
  ## accepted too.
  let t = opt.typename.multiReplace((" ", ""))
  t in ["bool", "system.bool", "Option[bool]", "options.Option[bool]",
        "Option[system.bool]", "options.Option[system.bool]"]

func matchesKey(spelling, key: string): bool =
  ## Whether a declared name or abbreviation `spelling` matches the key the
  ## user typed.  A single-character spelling is a SHORT switch and matches
  ## case-sensitively, so `-f` and `-F` can name different options (as they
  ## do in `tail`, `grep` and `ls`).  Longer spellings keep confutils' style-
  ## insensitive matching (`--output-dir` = `--Output-Dir` = `--OUTPUT-DIR`).
  if spelling.len == 0 or key.len == 0: return false
  if spelling.len == 1 or key.len == 1: spelling == key
  else: cmpIgnoreStyle(spelling, key) == 0

func findOpt(opts: openArray[OptInfo], name: string): OptInfo =
  # An empty key (a lone `-`, or `--=value`) names no option.  Compared
  # unguarded, it equalled the empty `abbr` of every option declared without
  # one, so `-` was read as the first such option.
  if name.len == 0: return nil
  for opt in opts:
    if matchesKey(opt.name, name) or matchesKey(opt.abbr, name):
      return opt

# returns the rest of args option if present.
# if it isn't on the last position or it's type is not seq[string]
# then this is misconfiguration and exception is thrown
# TODO the check if the rest of args is on the last position should happen compile time
func findRestOfArgs(opts: openArray[OptInfo]): OptInfo {.raises: [ConfigurationError].} =
  for i in 0..<opts.len:
    if opts[i].kind == RestOfArgs:
      if i != opts.len - 1 or opts[i].typename != "seq[string]":
        raise newException(ConfigurationError, "option with name " & opts[i].name &
                                              " of type restOfArgs must be the last option in the subcommand section and be of type seq[string]")
      return opts[i]

func findOpt(activeCmds: openArray[CmdInfo], name: string): OptInfo =
  for i in countdown(activeCmds.len - 1, 0):
    let found = findOpt(activeCmds[i].opts, name)
    if found != nil: return found

func findRestOfArgs(activeCmds: openArray[CmdInfo]): OptInfo {.raises: [ConfigurationError].} =
  for i in countdown(activeCmds.len - 1, 0):
    let found = findRestOfArgs(activeCmds[i].opts)
    if found != nil: return found

func findCmd(cmds: openArray[CmdInfo], name: string): CmdInfo =
  for cmd in cmds:
    if cmpIgnoreStyle(cmd.name, name) == 0:
      return cmd

func findSubCmd(cmd: CmdInfo, name: string): CmdInfo =
  let subCmdDiscriminator = cmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil:
    let cmd = findCmd(subCmdDiscriminator.subCmds, name)
    if cmd != nil: return cmd

  return nil

func startsWithIgnoreStyle(s: string, prefix: string): bool =
  # Similar in spirit to cmpIgnoreStyle, but compare only the prefix.
  var i = 0
  var j = 0

  while true:
    # Skip any underscore
    while i < s.len and s[i] == '_': inc i
    while j < prefix.len and prefix[j] == '_': inc j

    if j == prefix.len:
      # The whole prefix matches
      return true
    elif i == s.len:
      # We've reached the end of `s` without matching the prefix
      return false
    elif toLowerAscii(s[i]) != toLowerAscii(prefix[j]):
      return false

    inc i
    inc j

when defined(debugCmdTree):
  proc printCmdTree(cmd: CmdInfo, indent = 0) =
    let blanks = spaces(indent)
    echo blanks, "> ", cmd.name

    for opt in cmd.opts:
      if opt.kind == Discriminator:
        for subcmd in opt.subCmds:
          printCmdTree(subcmd, indent + 2)
      else:
        echo blanks, "  - ", opt.name, ": ", opt.typename

else:
  template printCmdTree(cmd: CmdInfo) = discard

# TODO remove the overloads here to get better "missing overload" error message
proc parseCmdArg*(T: type InputDir, p: string): T {.raises: [ValueError].} =
  if not dirExists(p):
    raise newException(ValueError, "Directory doesn't exist")

  T(p)

proc parseCmdArg*(T: type InputFile, p: string): T {.raises: [ValueError].} =
  # TODO this is needed only because InputFile cannot be made
  # an alias of TypedInputFile at the moment, because of a generics
  # caching issue
  if not fileExists(p):
    raise newException(ValueError, "File doesn't exist")

  when not defined(nimscript):
    try:
      let f = system.open(p, fmRead)
      close f
    except IOError:
      raise newException(ValueError, "File not accessible")

  T(p)

proc parseCmdArg*(
    T: type TypedInputFile, p: string): T {.raises: [ValueError].} =
  var path = p
  when T.defaultExt.len > 0:
    path = path.addFileExt(T.defaultExt)

  if not fileExists(path):
    raise newException(ValueError, "File doesn't exist")

  when not defined(nimscript):
    try:
      let f = system.open(path, fmRead)
      close f
    except IOError:
      raise newException(ValueError, "File not accessible")

  T(path)

func parseCmdArg*(T: type[OutDir|OutFile|OutPath], p: string): T =
  T(p)

proc parseCmdArg*[T](
    _: type Option[T], s: string): Option[T] {.raises: [ValueError].} =
  some(parseCmdArg(T, s))

template parseCmdArg*(T: type string, s: string): string =
  s

func parseCmdArg*(
    T: type SomeSignedInt, s: string): T {.raises: [ValueError].} =
  T parseBiggestInt(s)

func parseCmdArg*(
    T: type SomeUnsignedInt, s: string): T {.raises: [ValueError].} =
  T parseBiggestUInt(s)

func parseCmdArg*(T: type SomeFloat, p: string): T {.raises: [ValueError].} =
  parseFloat(p)

func parseCmdArg*(T: type bool, p: string): T {.raises: [ValueError].} =
  try:
    p.len == 0 or parseBool(p)
  except CatchableError:
    raise newException(ValueError, "'" & p & "' is not a valid boolean value. Supported values are on/off, yes/no, true/false or 1/0")

func parseCmdArg*(T: type enum, s: string): T {.raises: [ValueError].} =
  parseEnum[T](s)

proc parseCmdArgAux(T: type, s: string): T {.raises: [ValueError].} =
  # The parseCmdArg procs are allowed to raise only `ValueError`.
  # If you have provided your own specializations, please handle
  # all other exception types.
  mixin parseCmdArg
  parseCmdArg(T, s)

func completeCmdArg*(T: type enum, val: string): seq[string] =
  for e in low(T)..high(T):
    let as_str = $e
    if startsWithIgnoreStyle(as_str, val):
      result.add($e)

func completeCmdArg*(T: type SomeNumber, val: string): seq[string] =
  @[]

func completeCmdArg*(T: type bool, val: string): seq[string] =
  @[]

func completeCmdArg*(T: type string, val: string): seq[string] =
  @[]

proc completeCmdArg*(T: type[InputFile|TypedInputFile|InputDir|OutFile|OutDir|OutPath],
                     val: string): seq[string] =
  when not defined(nimscript):
    let (dir, name, ext) = splitFile(val)
    let tail = name & ext
    # Expand the directory component for the directory walker routine
    let dir_path = if dir == "": "." else: expandTilde(dir)
    # Dotfiles are hidden unless the user entered a dot as prefix
    let show_dotfiles = len(name) > 0 and name[0] == '.'

    try:
      for kind, path in walkDir(dir_path, relative=true):
        if not show_dotfiles and path[0] == '.':
          continue

        # Do not show files if asked for directories, on the other hand we must show
        # directories even if a file is requested to allow the user to select a file
        # inside those
        if type(T) is (InputDir or OutDir) and kind notin {pcDir, pcLinkToDir}:
          continue

        # Note, no normalization is needed here
        if path.startsWith(tail):
          var match = dir_path / path
          # Add a trailing slash so that completions can be chained
          if kind in {pcDir, pcLinkToDir}:
            match &= DirSep

          result.add(shellPathEscape(match))
    except OSError:
      discard

func completeCmdArg*[T](_: type seq[T], val: string): seq[string] =
  @[]

proc completeCmdArg*[T](_: type Option[T], val: string): seq[string] =
  mixin completeCmdArg
  return completeCmdArg(type(T), val)

proc completeCmdArgAux(T: type, val: string): seq[string] =
  mixin completeCmdArg
  return completeCmdArg(T, val)

template setField[T](loc: var T, val: Option[string], defaultVal: untyped) =
  type FieldType = type(loc)
  loc = if isSome(val): parseCmdArgAux(FieldType, val.get)
        else: FieldType(defaultVal)

template setField[T](loc: var seq[T], val: Option[string], defaultVal: untyped) =
  if val.isSome:
    loc.add parseCmdArgAux(type(loc[0]), val.get)
  else:
    type FieldType = type(loc)
    loc = FieldType(defaultVal)

func makeDefaultValue*(T: type): T =
  default(T)

func requiresInput*(T: type): bool =
  not ((T is seq) or (T is Option) or (T is bool))

func acceptsMultipleValues*(T: type): bool =
  T is seq

template debugMacroResult(macroName: string) {.dirty.} =
  when defined(debugMacros) or defined(debugConfutils):
    echo "\n-------- ", macroName, " ----------------------"
    echo result.repr

func parseEnumNormalized[T: enum](s: string): T {.raises: [ValueError].} =
  # Note: In Nim 1.6 `parseEnum` normalizes the string except for the first
  # character. Nim 1.2 would normalize for all characters. In config options
  # the latter behaviour is required so this custom function is needed.
  genEnumCaseStmt(T, s, default = nil, ord(low(T)), ord(high(T)), normalize)

proc generateFieldSetters(RecordType: NimNode): NimNode =
  var recordDef = getImpl(RecordType)
  let makeDefaultValue = bindSym"makeDefaultValue"

  result = newTree(nnkStmtListExpr)
  var settersArray = newTree(nnkBracket)

  for field in recordFields(recordDef):
    var
      setterName = ident($field.name & "Setter")
      fieldName = field.name
      namePragma = field.readPragma"name"
      paramName = if namePragma != nil: namePragma
                  else: fieldName
      configVar = ident "config"
      configField = newTree(nnkDotExpr, configVar, fieldName)
      defaultValue = field.readPragma"defaultValue"
      completerName = ident($field.name & "Complete")

    if defaultValue == nil:
      defaultValue = newCall(makeDefaultValue, newTree(nnkTypeOfExpr, configField))

    # TODO: This shouldn't be necessary. The type symbol returned from Nim should
    # be typed as a tyTypeDesc[tyString] instead of just `tyString`. To be filed.
    var fixedFieldType = newTree(nnkTypeOfExpr, field.typ)

    settersArray.add newTree(nnkTupleConstr,
                             newLit($paramName),
                             setterName, completerName,
                             newCall(bindSym"requiresInput", fixedFieldType),
                             newCall(bindSym"acceptsMultipleValues", fixedFieldType))

    result.add quote do:
      {.push hint[XCannotRaiseY]: off.}

    result.add quote do:
      proc `completerName`(val: string): seq[string] {.
        nimcall
        gcsafe
        sideEffect
        raises: []
      .} =
        return completeCmdArgAux(`fixedFieldType`, val)

      proc `setterName`(`configVar`: var `RecordType`, val: Option[string]) {.
        nimcall
        gcsafe
        sideEffect
        raises: [ValueError]
      .} =
        when `configField` is enum:
          # TODO: For some reason, the normal `setField` rejects enum fields
          # when they are used as case discriminators. File this as a bug.
          if isSome(val):
            `configField` = parseEnumNormalized[type(`configField`)](val.get)
          else:
            `configField` = `defaultValue`
        else:
          setField(`configField`, val, `defaultValue`)

    result.add quote do:
      {.pop.}

  result.add settersArray
  debugMacroResult "Field Setters"

func checkDuplicate(cmd: CmdInfo, opt: OptInfo, fieldName: NimNode) =
  for x in cmd.opts:
    if opt.name == x.name:
      error "duplicate name detected: " & opt.name, fieldName
    if opt.abbr.len > 0 and opt.abbr == x.abbr:
      error "duplicate abbr detected: " & opt.abbr, fieldName

func validPath(path: var seq[CmdInfo], parent, node: CmdInfo): bool =
  for x in parent.opts:
    if x.kind != Discriminator: continue
    for y in x.subCmds:
      if y == node:
        path.add y
        return true
      if validPath(path, y, node):
        path.add y
        return true
  false

func findPath(parent, node: CmdInfo): seq[CmdInfo] =
  # find valid path from parent to node
  result = newSeq[CmdInfo]()
  doAssert validPath(result, parent, node)
  result.add parent

func toText(n: NimNode): string =
  if n == nil: ""
  elif n.kind in {nnkStrLit..nnkTripleStrLit}: n.strVal
  else: repr(n)

proc pragmaText(n: NimNode, pragmaName: string): string =
  ## The string a text pragma (`desc`, `longDesc`, ...) carries.  Besides a
  ## literal, accept a NAMED string constant: an expression (`"a" & B`) is
  ## folded to a literal by the compiler, but a bare constant reaches the
  ## macro as a symbol, and `strVal` of a symbol is its NAME -- which used to
  ## turn `{.desc: SomeConst.}` silently into the help text "SomeConst".
  case n.kind
  of nnkStrLit..nnkTripleStrLit:
    n.strVal
  of nnkSym:
    if n.symKind == nskConst:
      let impl = n.getImpl
      if impl.kind == nnkConstDef and
         impl[^1].kind in {nnkStrLit..nnkTripleStrLit}:
        return impl[^1].strVal
    error "the {." & pragmaName & ".} pragma needs a string literal or a " &
          "string constant", n
    ""
  else:
    error "the {." & pragmaName & ".} pragma needs a string literal or a " &
          "string constant", n
    ""

proc cmdInfoFromType(T: NimNode): CmdInfo =
  result = CmdInfo()

  var
    recordDef = getImpl(T)
    discriminatorFields = newSeq[OptInfo]()
    fieldIdx = 0
    fieldIdxByName: seq[string]   # Nim field name at each setter index

  for field in recordFields(recordDef):
    fieldIdxByName.add $field.name

  for field in recordFields(recordDef):
    let
      isImplicitlySelectable = field.readPragma"implicitlySelectable" != nil
      defaultValue = field.readPragma"defaultValue"
      defaultValueDesc = field.readPragma"defaultValueDesc"
      defaultInHelp = if defaultValueDesc != nil: defaultValueDesc
                      else: defaultValue
      defaultInHelpText = toText(defaultInHelp)
      separator = field.readPragma"separator"
      longDesc = field.readPragma"longDesc"

      isHidden = field.readPragma("hidden") != nil
      abbr = field.readPragma"abbr"
      name = field.readPragma"name"
      desc = field.readPragma"desc"
      optKind = if field.isDiscriminator: Discriminator
                elif field.readPragma("argument") != nil: Arg
                elif field.readPragma("restOfArgs") != nil: RestOfArgs
                else: CliSwitch

    var opt = OptInfo(kind: optKind,
                      idx: fieldIdx,
                      name: $field.name,
                      isHidden: isHidden,
                      hasDefault: defaultValue != nil,
                      defaultInHelpText: defaultInHelpText,
                      typename: field.typ.repr)

    if desc != nil: opt.desc = pragmaText(desc, "desc")
    if name != nil: opt.name = pragmaText(name, "name")
    if abbr != nil: opt.abbr = pragmaText(abbr, "abbr")
    if separator != nil: opt.separator = pragmaText(separator, "separator")
    if longDesc != nil: opt.longDesc = pragmaText(longDesc, "longDesc")

    let
      implicitVal = field.readPragma"implicitValue"
      alsoSets = field.readPragma"alsoSets"
      valueName = field.readPragma"valueName"
    if implicitVal != nil:
      opt.hasImplicitValue = true
      opt.implicitValue = pragmaText(implicitVal, "implicitValue")
    if valueName != nil:
      opt.valueName = pragmaText(valueName, "valueName")
    opt.alsoSetsIdx = -1
    if alsoSets != nil:
      if alsoSets.kind notin {nnkCall, nnkCallStrLit} or alsoSets.len != 3:
        error "{.alsoSets.} takes two arguments: a field name and a value",
              alsoSets
      let target = pragmaText(alsoSets[1], "alsoSets")
      opt.alsoSetsValue = pragmaText(alsoSets[2], "alsoSets")
      opt.alsoSetsIdx = fieldIdxByName.find(target)
      if opt.alsoSetsIdx < 0:
        error "{.alsoSets.} names no field of this type: " & target, alsoSets
      if opt.alsoSetsIdx == fieldIdx:
        error "{.alsoSets.} cannot name the option's own field", alsoSets

    inc fieldIdx

    if field.isDiscriminator:
      discriminatorFields.add opt
      let cmdType = field.typ.getImpl[^1]
      if cmdType.kind != nnkEnumTy:
        error "Only enums are supported as case object discriminators", field.name

      opt.isImplicitlySelectable = isImplicitlySelectable
      opt.isCommand = field.readPragma"command" != nil

      for i in 1 ..< cmdType.len:
        let enumVal = cmdType[i]
        var name, desc: string
        if enumVal.kind == nnkEnumFieldDef:
          name = $enumVal[0]
          desc = $enumVal[1]
        else:
          name = $enumVal
        if defaultValue != nil and eqIdent(name, defaultValue):
          opt.defaultSubCmd = i - 1
        opt.subCmds.add CmdInfo(name: name, desc: desc)

      if defaultValue == nil:
        opt.defaultSubCmd = -1
      else:
        if opt.defaultSubCmd == -1:
          error "The default value is not a valid enum value", defaultValue

    if field.caseField != nil and field.caseBranch != nil:
      let fieldName = field.caseField.getFieldName
      var discriminator = findOpt(discriminatorFields, $fieldName)

      if discriminator == nil:
        error "Unable to find " & $fieldName

      if field.caseBranch.kind == nnkElse:
        error "Sub-command parameters cannot appear in an else branch. " &
              "Please specify the sub-command branch precisely", field.caseBranch[0]

      var branchEnumVal = field.caseBranch[0]
      if branchEnumVal.kind == nnkDotExpr:
        branchEnumVal = branchEnumVal[1]
      var cmd = findCmd(discriminator.subCmds, $branchEnumVal)
      # we respect subcommand hierarchy when looking for duplicate
      let path = findPath(result, cmd)
      for n in path:
        checkDuplicate(n, opt, field.name)

      # the reason we check for `ignore` pragma here and not using `continue` statement
      # is we do respect option hierarchy of subcommands
      if field.readPragma("ignore") == nil:
        if optKind == RestOfArgs:
          for i, previousOpt in cmd.opts:
            let isRequired = not previousOpt.hasDefault
            let isRequiredArg = isRequired and previousOpt.kind == Arg
            if not isRequiredArg: # and previousOpt.kind == Arg:
              # echo previousOpt.repr
              error "not supported: non-required args before {.restOfArgs.}: " &
                opt.name, field.name
          cmd.hasRestOfArgs = true
        elif cmd.hasRestOfArgs:
          # arg or cli switch after rest: wrong
          error "{.restOfArgs.} field can only be the last one in a command, but followed by: " &
            field.name.repr, field.name
        cmd.opts.add opt

    else:
      checkDuplicate(result, opt, field.name)

      if field.readPragma("ignore") == nil:
        result.opts.add opt

macro configurationRtti(RecordType: type): untyped =
  let
    T = RecordType.getType[1]
    cmdInfo = cmdInfoFromType T
    fieldSetters = generateFieldSetters T

  result = newTree(nnkPar, newLitFixed cmdInfo, fieldSetters)

# ---------------------------------------------------------------------------
# Compile-time bridge: convert the existing ``CmdInfo`` IR into a runtime
# ``RuntimeCommandSurface`` value. This re-uses the rich pragma extraction
# done by ``cmdInfoFromType`` and translates its result into the plain-data
# surface type that the runtime algorithms operate on.
#
# Layering: existing confutils users keep their compile-time typed configs
# unchanged. The bridge gives them a `RuntimeCommandSurface` literal that
# can be fed into the runtime help / completion / merge algorithms.
# ---------------------------------------------------------------------------

func cmdInfoToRuntimeFlag(opt: OptInfo): RuntimeFlag =
  ## Translate an :type:`OptInfo` CLI-switch entry into a plain
  ## :type:`RuntimeFlag`.
  result.name = opt.name
  if opt.abbr.len == 1:
    result.short = opt.abbr[0]
  elif opt.abbr.len > 1:
    # A multi-character abbreviation is a second LONG spelling (`findOpt`
    # matches it against the key of `--abbr`); truncating it to its first
    # character would advertise a switch the parser does not accept.
    result.aliases.add opt.abbr
  result.description = opt.desc
  result.longDescription = opt.longDesc
  result.typeHint = opt.typename
  result.required = not opt.hasDefault
  result.default = opt.defaultInHelpText
  result.takesValue = not opt.isSwitch
  result.valueOptional = opt.hasImplicitValue
  result.valueName = opt.valueName

func cmdInfoToRuntimeCommand(cmd: CmdInfo): RuntimeCommand =
  ## Translate an :type:`CmdInfo` (including its options and recursive
  ## sub-command discriminator) into a :type:`RuntimeCommand`.
  result.name = cmd.name
  result.description = cmd.desc
  for opt in cmd.opts:
    case opt.kind
    of CliSwitch:
      if not opt.isHidden:
        result.flags.add cmdInfoToRuntimeFlag(opt)
    of Discriminator:
      if opt.isCommand:
        for sub in opt.subCmds:
          result.subcommands.add cmdInfoToRuntimeCommand(sub)
    else:
      discard

func cmdInfoToRuntimeSurface(
    cmd: CmdInfo, programName: string): RuntimeCommandSurface =
  ## Translate the top-level :type:`CmdInfo` into a full surface. CLI
  ## switches at the root become global flags; sub-commands of any
  ## ``{.command.}`` discriminator become top-level commands.
  result.programName = programName
  for opt in cmd.opts:
    case opt.kind
    of CliSwitch:
      if not opt.isHidden:
        result.globalFlags.add cmdInfoToRuntimeFlag(opt)
    of Discriminator:
      if opt.isCommand:
        for sub in opt.subCmds:
          result.commands.add cmdInfoToRuntimeCommand(sub)
    else:
      discard

macro surfaceFromType*(
    T: typedesc; programName: static string = ""): RuntimeCommandSurface =
  ## Compile-time bridge: introspect a Nim object type used as a confutils
  ## configuration and emit a :type:`RuntimeCommandSurface` literal at
  ## compile time. The bridge is transparent: existing confutils users see
  ## no behavioural change, but help formatting, completion generation and
  ## merging can now run over the resulting runtime surface.
  let
    typeSym = T.getType[1]
    cmdInfo = cmdInfoFromType typeSym
    surface = cmdInfoToRuntimeSurface(cmdInfo, programName)
  result = newLitFixed surface

proc addConfigFile*(secondarySources: auto,
                    Format: type,
                    path: InputFile) {.raises: [ConfigurationError].} =
  try:
    secondarySources.data.add loadFile(Format, string path,
                                       type(secondarySources.data[0]))
  except SerializationError as err:
    raise newException(ConfigurationError, err.formatMsg(string path), err)
  except IOError as err:
    raise newException(ConfigurationError,
      "Failed to read config file at '" & string(path) & "': " & err.msg)

proc addConfigFileContent*(secondarySources: auto,
                           Format: type,
                           content: string) =
  try:
    secondarySources.data.add decode(Format, content,
                                     type(secondarySources.data[0]))
  except SerializationError as err:
    raise newException(ConfigurationError, err.formatMsg("<content>"), err)
  except IOError:
    raiseAssert "This should not be possible"

func constructEnvKey*(prefix: string, key: string): string {.raises: [].} =
  ## Generates env. variable names from keys and prefix following the
  ## IEEE Open Group env. variable spec: https://pubs.opengroup.org/onlinepubs/000095399/basedefs/xbd_chap08.html
  try:
    (&"{prefix}_{key}").toUpperAscii.multiReplace(("-", "_"), (" ", "_"))
  except ValueError as err:
    raiseAssert "strformat.`&` failed: " & err.msg

proc newConfigurationError(kind: ConfigurationErrorKind,
                           msg, option, optionName, value,
                           detail: string): ref ConfigurationError =
  result = newException(ConfigurationError, msg)
  result.kind = kind
  result.option = option
  result.optionName = optionName
  result.value = value
  result.detail = detail

func isTruthy(value: string): bool =
  ## How a switch (`bool` field) reads its value: bare is true.
  value.len == 0 or (try: parseBool(value) except ValueError: false)

func isExplicitFalse(value: string): bool =
  ## A switch value that `parseBool` reads as false (`false`, `off`, `no`,
  ## `0`, ...).  A value it cannot read is not one: that is left to the
  ## field's setter, which rejects it as an invalid value.
  value.len > 0 and (try: not parseBool(value) except ValueError: false)

proc loadImpl[C, SecondarySources](
    Configuration: typedesc[C],
    cmdLine = commandLineParams(),
    version = "",
    copyrightBanner = "",
    printUsage = true,
    quitOnFailure = true,
    secondarySourcesRef: ref SecondarySources,
    secondarySources: proc (
        config: Configuration, sources: ref SecondarySources
    ) {.gcsafe, raises: [ConfigurationError].} = nil,
    envVarsPrefix = getAppFilename(),
    negatableSwitches = true
): Configuration {.raises: [ConfigurationError].} =
  ## Loads a program configuration by parsing command-line arguments
  ## and a standard set of config files that can specify:
  ##
  ##  - working directory settings
  ##  - user settings
  ##  - system-wide setttings
  ##
  ##  Supports multiple config files format (INI/TOML, YAML, JSON).

  # This is an initial naive implementation that will be improved
  # over time.
  let (rootCmd, fieldSetters) = configurationRtti(Configuration)
  var fieldCounters: array[fieldSetters.len, int]

  printCmdTree rootCmd

  var activeCmds = @[rootCmd]
  template lastCmd: auto = activeCmds[^1]
  var nextArgIdx = lastCmd.getNextArgIdx(-1)

  var help = ""

  proc suggestCallingHelp =
    errorOutput "Try ", fgCommand, ("$1 --help" % appInvocation())
    errorOutput " for more information.\p"
    flushOutputAndQuit QuitFailure

  template fail(errKind: ConfigurationErrorKind,
                errOption, errOptionName, errValue, errDetail, errMsg: string,
                styled: varargs[untyped]) =
    ## Report a command-line error.  When quitting on failure, `styled` is
    ## printed (with colours) and the process exits; otherwise the error is
    ## RAISED, carrying `errMsg` and the structured fields, so that a library
    ## caller can return it -- an empty message here used to leave such a
    ## caller with nothing to tell its user.
    if quitOnFailure:
      errorOutput styled
      errorOutput "\p"
      suggestCallingHelp()
    else:
      raise newConfigurationError(errKind, errMsg, errOption, errOptionName,
                                  errValue, errDetail)

  template fail(errKind: ConfigurationErrorKind, errMsg: string) =
    fail(errKind, "", "", "", "", errMsg, errMsg)

  let confAddr = addr result

  template applySetter(setterIdx: int, cmdLineVal: string,
                       switchText = "") =
    # echo "applySetter ", setterIdx, " ", cmdLineVal
    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]:off.}

    try:
      # echo "apply value ", cmdLineVal, " to argument ",fieldSetters[setterIdx][0]
      fieldSetters[setterIdx][1](confAddr[], some(cmdLineVal))
      inc fieldCounters[setterIdx]
    except:
      let
        setterName = fieldSetters[setterIdx][0]
        detail = getCurrentExceptionMsg()
      fail(cekInvalidValue,
           (if switchText.len > 0: switchText else: setterName),
           setterName, cmdLineVal, detail,
           "Error while processing the " & setterName & "=" & cmdLineVal &
             " parameter: " & detail,
           "Error while processing the ",
           fgOption, setterName,
           "=", cmdLineVal, resetStyle, " parameter: ",
           detail)

    when defined(nimHasWarnBareExcept):
      {.pop.}

  template applyOption(opt: OptInfo, cmdLineVal: string, switchText: string) =
    ## Apply a value given on the command line to `opt`'s field, then to its
    ## `{.alsoSets.}` target (for a switch, only when it is set to true).
    applySetter(opt.idx, cmdLineVal, switchText)
    if opt.alsoSetsIdx >= 0 and
       (not opt.isSwitch or isTruthy(cmdLineVal)):
      applySetter(opt.alsoSetsIdx, opt.alsoSetsValue, switchText)

  proc acceptsValue(setterIdx: int, value: string): bool =
    ## Whether the field's setter accepts `value`, decided on a scratch copy
    ## so that a rejected probe changes nothing.
    var probe = confAddr[]
    try:
      fieldSetters[setterIdx][1](probe, some(value))
      true
    except CatchableError:
      false

  when hasCompletions:
    template getArgCompletions(opt: OptInfo, prefix: string): seq[string] =
      fieldSetters[opt.idx][2](prefix)

  template required(opt: OptInfo): bool =
    fieldSetters[opt.idx][3] and not opt.hasDefault

  template activateCmd(discriminator: OptInfo, activatedCmd: CmdInfo) =
    let cmd = activatedCmd
    applySetter(discriminator.idx, if cmd.desc.len > 0: cmd.desc
                                   else: cmd.name)
    activeCmds.add cmd
    nextArgIdx = cmd.getNextArgIdx(-1)

  when hasCompletions:
    type
      ArgKindFilter = enum
        argName
        argAbbr

    proc showMatchingOptions(cmd: CmdInfo, prefix: string, filterKind: set[ArgKindFilter]) =
      var matchingOptions: seq[OptInfo]

      if len(prefix) > 0:
        # Filter the options according to the input prefix
        for opt in cmd.opts:
          if argName in filterKind and len(opt.name) > 0:
            if startsWithIgnoreStyle(opt.name, prefix):
              matchingOptions.add(opt)
          if argAbbr in filterKind and len(opt.abbr) > 0:
            if startsWithIgnoreStyle(opt.abbr, prefix):
              matchingOptions.add(opt)
      else:
        matchingOptions = cmd.opts

      for opt in matchingOptions:
        # The trailing '=' means the switch accepts an argument
        let trailing = if not opt.isSwitch: "=" else: ""

        if argName in filterKind and len(opt.name) > 0:
          try:
            stdout.writeLine("--", opt.name, trailing)
          except IOError:
            discard
        if argAbbr in filterKind and len(opt.abbr) > 0:
          try:
            stdout.writeLine('-', opt.abbr, trailing)
          except IOError:
            discard

    # Shell completion is the PROGRAM's job: it answers `COMP_LINE` on stdout
    # and returns an unparsed, default configuration.  A library caller (one
    # that does not quit on failure) parses a command line it was handed, so a
    # `COMP_LINE` that happens to be in its environment must not turn the parse
    # into a silent no-op that drops every option.
    let completion =
      if quitOnFailure: splitCompletionLine() else: newSeq[string]()
    # If we're not asked to complete a command line the result is an empty list
    if len(completion) != 0:
      var cmdStack = @[rootCmd]
      # Try to understand what the active chain of commands is without parsing the
      # whole command line
      for tok in completion[1..^1]:
        if not tok.startsWith('-'):
          let subCmd = findSubCmd(cmdStack[^1], tok)
          if subCmd != nil: cmdStack.add(subCmd)

      let cur_word = completion[^1]
      let prev_word = if len(completion) > 2: completion[^2] else: ""
      let prev_prev_word = if len(completion) > 3: completion[^3] else: ""

      if cur_word.startsWith('-'):
        # Show all the options matching the prefix input by the user
        let isFullName = cur_word.startsWith("--")
        var option_word = cur_word
        option_word.removePrefix('-')

        for i in countdown(cmdStack.len - 1, 0):
          let argFilter =
            if isFullName:
              {argName}
            elif len(cur_word) > 1:
              # If the user entered a single hypen then we show both long & short
              # variants
              {argAbbr}
            else:
              {argName, argAbbr}

          showMatchingOptions(cmdStack[i], option_word, argFilter)
      elif (prev_word.startsWith('-') or
          (prev_word == "=" and prev_prev_word.startsWith('-'))):
        # Handle cases where we want to complete a switch choice
        # -switch
        # -switch=
        var option_word = if len(prev_word) == 1: prev_prev_word else: prev_word
        option_word.removePrefix('-')

        let opt = findOpt(cmdStack, option_word)
        if opt != nil:
          for arg in getArgCompletions(opt, cur_word):
            try:
              stdout.writeLine(arg)
            except IOError:
              discard
      elif cmdStack[^1].hasSubCommands:
        # Show all the available subcommands
        for subCmd in subCmds(cmdStack[^1]):
          if startsWithIgnoreStyle(subCmd.name, cur_word):
            try:
              stdout.writeLine(subCmd.name)
            except IOError:
              discard
      else:
        # Full options listing
        for i in countdown(cmdStack.len - 1, 0):
          showMatchingOptions(cmdStack[i], "", {argName, argAbbr})

      stdout.flushFile()

      return

  proc lazyHelpAppInfo: HelpAppInfo =
    HelpAppInfo(
      copyrightBanner: copyrightBanner,
      appInvocation: appInvocation())

  proc helpOwnsShortH(): bool =
    ## `-h` asks for help unless an option of the active commands claims the
    ## abbreviation `h` for something else.  (An option NAMED `help` with
    ## `abbr: "h"` only documents the switch, so it does not count.)
    let claimed = findOpt(activeCmds, "h")
    claimed == nil or cmpIgnoreStyle(claimed.name, "help") == 0

  template processHelpAndVersionOptions(optKey: string, switchText: string,
                                        isSwitch: bool) =
    let key = optKey
    # `-h` (and `--h`, which `findOpt` would otherwise match against an `h`
    # abbreviation) asks for help unless an option claims `h`.
    if cmpIgnoreStyle(key, "help") == 0 or
       (isSwitch and key == "h" and helpOwnsShortH()):
      if quitOnFailure:
        help.showHelp lazyHelpAppInfo(), activeCmds
      else:
        # A library caller renders help itself; showing it here would also
        # QUIT the caller's process.
        raise newConfigurationError(cekHelpRequested, "help was requested",
                                    switchText, "help", "", "")
    elif version.len > 0 and cmpIgnoreStyle(key, "version") == 0:
      if quitOnFailure:
        help.helpOutput version, "\p"
        flushOutputAndQuit QuitSuccess
      else:
        raise newConfigurationError(cekVersionRequested,
                                    "version was requested", switchText,
                                    "version", "", "")

  var index = 0
  var parser = initOptParser(cmdLine)
  while true:
    next(parser)
    if parser.kind == cmdEnd: break
    let
      kind = parser.kind
      key = parser.key
      val = parser.val
      valGiven = parser.valGiven

    # echo "active len:", activeCmds.len, " key:", key, " hasRestOfArgs:", lastCmd.hasRestOfArgs, " #", index, " lastCmd opts len:", lastCmd.opts.len

    if activeCmds.len > 0 and lastCmd.hasRestOfArgs and
        index >= lastCmd.opts.len: # 1 (cmd) + lastCmd.opts.len - 1 (all before rest)
      # add all others in the simplest way possible to the rest of args seq
      # assume we're on param index(0-based): index + 1 in param index(starting from 1)
      # var restOfArgs: seq[string] = @[]
      for i in index + 1 .. paramCount():
        applySetter(lastCmd.opts[^1].idx, paramStr(i))
      break
    index += 1

    case kind
    of cmdLongOption, cmdShortOption:
      # if lastCmd.hasRestOfArgs:
      #   applySetter(lastCmd.opts[^1].idx, paramStr(index))
      #   continue
      let switchText = (if kind == cmdLongOption: "--" else: "-") & key
      processHelpAndVersionOptions key, switchText, true

      # echo "processing cli switch ", key, " with val ", val
      var opt = findOpt(activeCmds, key)
      if opt == nil:
        # We didn't find the option.
        # Check if it's from the default command and activate it if necessary:
        let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
        if subCmdDiscriminator != nil:
          if subCmdDiscriminator.defaultSubCmd != -1:
            let defaultCmd = subCmdDiscriminator.subCmds[subCmdDiscriminator.defaultSubCmd]
            opt = findOpt(defaultCmd.opts, key)
            if opt != nil:
              activateCmd(subCmdDiscriminator, defaultCmd)
          else:
            discard

      if opt == nil:
        # `value` carries an in-token value (`--name=value`), so a caller can
        # echo the whole token back.
        fail(cekUnknownOption, switchText, "", (if valGiven: val else: ""), "",
             "Unrecognized option '" & key & "'",
             "Unrecognized option '" & key & "'")
      elif opt.isSwitch or valGiven:
        # A switch takes no value from the next token (`--flag=false` still
        # works, unless `negatableSwitches` is off), and `--name=value`
        # carries its own.
        if opt.isSwitch and valGiven and not negatableSwitches and
           isExplicitFalse(val):
          let detail = switchText & " is a switch: it is on when given and " &
                       "off when omitted, so it takes no false value (got '" &
                       switchText & "=" & val & "')"
          fail(cekInvalidValue, switchText, opt.name, val, detail, detail,
               detail)
        applyOption(opt, val, switchText)
      else:
        # `--name value` / `-n value`: the value is the next token.
        var tok: string
        let inCluster = parser.nextTokenIsInCluster
        if opt.hasImplicitValue:
          # OPTIONAL value: take the next token only when it is a value this
          # option accepts, so that a bare `--name` stays usable right before
          # another option or a positional argument.
          if parser.peekValueToken(tok) and not inCluster and
             (tok.len == 0 or tok[0] != '-') and acceptsValue(opt.idx, tok):
            discard parser.takeValueToken(tok)
            index += 1
            applyOption(opt, tok, switchText)
          else:
            applyOption(opt, opt.implicitValue, switchText)
        elif parser.takeValueToken(tok):
          # The next token is the value VERBATIM, even when it begins with
          # `-`: the option asked for a value, and a value such as `-` (stdin)
          # or `-5` is legitimate.  This used to be a "pending" option that
          # only a following positional token completed, so a value-taking
          # option followed by another option, or last on the command line,
          # was silently dropped.
          if not inCluster: index += 1
          applyOption(opt, tok, switchText)
        else:
          let shown = if opt.valueName.len > 0: " <" & opt.valueName & ">"
                      else: ""
          fail(cekMissingValue, switchText, opt.name, "", "",
               "The option '" & switchText & "' requires a value" & shown,
               "The option '", fgOption, switchText, resetStyle,
               "' requires a value", shown)

    of cmdArgument:
      # echo "process cmd option ", key
      if lastCmd.hasSubCommands:
        processHelpAndVersionOptions key, key, false

      block processArg:
        let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
        if subCmdDiscriminator != nil:
          let subCmd = findCmd(subCmdDiscriminator.subCmds, key)
          if subCmd != nil:
            # echo "cmd is ", key
            activateCmd(subCmdDiscriminator, subCmd)
            break processArg

        if nextArgIdx == -1:
          let msg = lastCmd.noMoreArgsError
          fail(cekUnexpectedArgument, key, "", key, "", msg, msg)

        applySetter(nextArgIdx, key)

        if not fieldSetters[nextArgIdx][4]:
          nextArgIdx = lastCmd.getNextArgIdx(nextArgIdx)

    else:
      discard

  let subCmdDiscriminator = lastCmd.getSubCmdDiscriminator
  if subCmdDiscriminator != nil and
     subCmdDiscriminator.defaultSubCmd != -1 and
     fieldCounters[subCmdDiscriminator.idx] == 0:
    let defaultCmd = subCmdDiscriminator.subCmds[subCmdDiscriminator.defaultSubCmd]
    activateCmd(subCmdDiscriminator, defaultCmd)

  if secondarySources != nil:
    try:
      secondarySources(result, secondarySourcesRef)
    except ConfigurationError as err:
      fail(cekOther, "Failed to load secondary sources: '" & err.msg & "'")

  proc processMissingOpts(
      conf: var Configuration, cmd: CmdInfo) {.raises: [ConfigurationError].} =
    for opt in cmd.opts:
      if fieldCounters[opt.idx] == 0:
        # An EMPTY prefix turns the environment off: otherwise every option
        # not given on the command line is looked up as `_<NAME>`, and a
        # program that reads its environment explicitly (or whose options'
        # names collide with another tool's variables) cannot opt out.
        let envKey =
          if envVarsPrefix.len > 0: constructEnvKey(envVarsPrefix, opt.name)
          else: ""

        try:
          if envKey.len > 0 and existsEnv(envKey):
            let envContent = getEnv(envKey)
            applySetter(opt.idx, envContent, envKey)
          elif secondarySourcesRef.setters[opt.idx](conf, secondarySourcesRef):
            # all work is done in the config file setter,
            # there is nothing left to do here.
            discard
          elif opt.hasDefault:
            fieldSetters[opt.idx][1](conf, none[string]())
          elif opt.required:
            let msg = "The required option '" & opt.name & "' was not specified"
            fail(cekMissingRequired, "--" & opt.name, opt.name, "", "", msg,
                 msg)
        except ValueError as err:
          let msg = "Option '" & opt.name & "' failed to parse: '" & err.msg & "'"
          fail(cekInvalidValue, "--" & opt.name, opt.name, "", err.msg, msg,
               msg)

  for cmd in activeCmds:
    result.processMissingOpts(cmd)

template load*(
    Configuration: type,
    cmdLine = commandLineParams(),
    version = "",
    copyrightBanner = "",
    printUsage = true,
    quitOnFailure = true,
    secondarySources: untyped = nil,
    envVarsPrefix = getAppFilename(),
    negatableSwitches = true): untyped =
  ## `negatableSwitches = false` refuses a switch (a `bool` field) given an
  ## explicit false value (`--flag=false`, `--flag=off`) instead of applying
  ## it.  A switch is on when given and off when omitted, so for a program
  ## whose switches cannot be turned off again (because a default or another
  ## option decides the setting) a negated spelling would be accepted and do
  ## nothing -- that program passes `false`.

  block:
    var secondarySourcesRef = generateSecondarySources(Configuration)
    loadImpl(Configuration, cmdLine, version,
             copyrightBanner, printUsage, quitOnFailure,
             secondarySourcesRef, secondarySources, envVarsPrefix,
             negatableSwitches)

func defaults*(Configuration: type): Configuration =
  load(Configuration, cmdLine = @[], printUsage = false, quitOnFailure = false)

proc dispatchImpl(cliProcSym, cliArgs, loadArgs: NimNode): NimNode =
  # Here, we'll create a configuration object with fields matching
  # the CLI proc params. We'll also generate a call to the designated proc
  let configType = genSym(nskType, "CliConfig")
  let configFields = newTree(nnkRecList)
  let configVar = genSym(nskLet, "config")
  var dispatchCall = newCall(cliProcSym)

  # The return type of the proc is skipped over
  for i in 1 ..< cliArgs.len:
    var arg = copy cliArgs[i]

    # If an argument doesn't specify a type, we infer it from the default value
    if arg[1].kind == nnkEmpty:
      if arg[2].kind == nnkEmpty:
        error "Please provide either a default value or type of the parameter", arg
      arg[1] = newCall(bindSym"typeof", arg[2])

    # Turn any default parameters into the confutils's `defaultValue` pragma
    if arg[2].kind != nnkEmpty:
      if arg[0].kind != nnkPragmaExpr:
        arg[0] = newTree(nnkPragmaExpr, arg[0], newTree(nnkPragma))
      arg[0][1].add newColonExpr(bindSym"defaultValue", arg[2])
      arg[2] = newEmptyNode()

    configFields.add arg
    dispatchCall.add newTree(nnkDotExpr, configVar, skipPragma arg[0])

  let cliConfigType = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      configType,
      newEmptyNode(),
      nnkObjectTy.newTree(
        newEmptyNode(),
        newEmptyNode(),
        configFields)))

  var loadConfigCall = newCall(bindSym"load", configType)
  for p in loadArgs: loadConfigCall.add p

  result = quote do:
    `cliConfigType`
    let `configVar` = `loadConfigCall`
    `dispatchCall`

macro dispatch*(fn: typed, args: varargs[untyped]): untyped =
  if fn.kind != nnkSym or
     fn.symKind notin {nskProc, nskFunc, nskMacro, nskTemplate}:
    error "The first argument to `confutils.dispatch` should be a callable symbol"

  let fnImpl = fn.getImpl
  result = dispatchImpl(fnImpl.name, fnImpl.params, args)
  debugMacroResult "Dispatch Code"

macro cli*(args: varargs[untyped]): untyped =
  if args.len == 0:
    error "The cli macro expects a do block", args

  let doBlock = args[^1]
  if doBlock.kind notin {nnkDo, nnkLambda}:
    error "The last argument to `confutils.cli` should be a do block", doBlock

  args.del(args.len - 1)

  # Create a new anonymous proc we'll dispatch to
  let cliProcName = genSym(nskProc, "CLI")
  var cliProc = newTree(nnkProcDef, cliProcName)
  # Copy everything but the name from the do block:
  for i in 1 ..< doBlock.len: cliProc.add doBlock[i]

  # Generate the final code
  result = newStmtList(cliProc, dispatchImpl(cliProcName, cliProc.params, args))

  # TODO: remove this once Nim supports custom pragmas on proc params
  for p in cliProc.params:
    if p.kind == nnkEmpty: continue
    p[0] = skipPragma p[0]

  debugMacroResult "CLI Code"

func load*(f: TypedInputFile): f.ContentType =
  when f.Format is Unspecified or f.ContentType is Unspecified:
    {.fatal: "To use `InputFile.load`, please specify the Format and ContentType of the file".}

  when f.Format is Txt:
    # TODO: implement a proper Txt serialization format
    mixin init
    f.ContentType.init readFile(f.string).string
  else:
    mixin loadFile
    loadFile(f.Format, f.string, f.ContentType)
