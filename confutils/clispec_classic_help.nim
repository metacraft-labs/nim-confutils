## Confutils' classic help screen, rendered from a clispec description.
##
## A program whose command line used to be a confutils configuration type
## (an object with ``{.desc.}``, ``{.abbr.}``, ``{.argument.}`` fields and
## ``case`` subcommands) can move that command line onto a clispec
## description and keep printing exactly the help confutils printed for the
## type: ``cliClassicHelp`` renders it, byte for byte, from the
## description's grammar. Clispec's own help (``Tool.helpText``) is a
## different layout; this module is for a program that must not change its
## help screens.
##
## .. code-block:: nim
##   import confutils/clispec_config     # exports this module
##
##   cliConfiguration(Tool, "tool"):
##     flag jobs is int, short = 'j', default = 4, help = "Parallel jobs"
##     subcmd "build":
##       pos target is string, help = "What to build"
##
##   echo Tool.cliClassicHelp(["build"], copyrightBanner = "Tool 1.0")
##   Tool.showClassicHelp([])            # to stdout, as confutils does
##
## The equivalent type
## ===================
##
## The screen is the one confutils prints for the type that declares, in the
## same order, the same parameters as the description:
##
## * a ``flag`` / ``boolFlag`` is a field (its long flag is the field's
##   ``{.name.}``), ``short = 'x'`` its ``{.abbr: "x".}`` and a long
##   ``alias = "--xy"`` a multi-character ``{.abbr: "xy".}``;
## * a ``pos`` is an ``{.argument.}`` field and a ``rest = true`` positional
##   a ``{.restOfArgs.}`` field;
## * ``help`` is ``{.desc.}`` (``%t`` in it is replaced with the type, as
##   confutils does), ``longHelp`` is ``{.longDesc.}``;
## * ``visibility = hidden`` (or ``internal``) is ``{.hidden.}``: not
##   listed, but still counted in the width of the name column, as confutils
##   counts hidden fields. A parameter whose ``sources`` exclude the command
##   line is not a field at all (``{.ignore.}``);
## * ``default = <expr>`` is ``{.defaultValue: <expr>.}``: help shows it as
##   written, a string literal unquoted (``[=@[]]``, ``[=Mode.off]``,
##   ``[=.]``), which is the text confutils shows. ``defaultValueDesc =
##   "<text>"`` (``confutils/clispec_config``) is ``{.defaultValueDesc.}``:
##   the text shown instead;
## * the subcommands of a command are the values of an enum
##   ``{.command.}`` discriminator declared after the command's other
##   fields, in the description's order; its ``call:`` is the discriminator's
##   ``{.defaultValue.}`` value, whose options confutils lists, without a
##   heading, after the command's own; a ``subcmd``'s ``help`` is the enum
##   value's string. Subcommands with ``visibility = hidden`` are left out
##   (an enum value cannot be hidden). The root command's ``help`` and the
##   subcommands' ``aliases`` have no counterpart in the type and are not
##   shown.
##
## Everything else follows confutils' renderer rule for rule: the banner,
## the ``Usage:`` frame, the colours (ANSI escapes as Nim's ``terminal``
## writes them, the reset after every write that confutils makes with a
## non-literal argument, and none with ``-d:confutils_no_colors``, which
## leaves the resets), positionals listed only when they are the command's
## last fields, the abbreviation column, a name column of ``min(18, longest
## name) + 6`` taken from the command whose help is shown, descriptions
## ending in `` [=<default>]`` and ``.``, wrapped to ``min(width - column,
## 80)`` with the narrow-terminal layout below 36 columns
## (``-d:confutils_description_width``, ``-d:confutils_narrow_terminal_width``
## change both renderers), and a block per subcommand under ``Available
## sub-commands:``, nested. The width defaults to ``terminalWidth()`` (which
## reads ``COLUMNS`` first), as confutils' does.
##
## Neither ``--help`` nor ``--version`` is listed, as confutils lists
## neither. The output uses ``\p`` line ends and ANSI escapes, which is what
## confutils writes on POSIX; on Windows confutils sets console attributes
## instead.

import std/[strutils, wordwrap, terminal]

import clispec

export clispec

const
  confutils_description_width {.intdefine.} = 80
    ## The same define confutils' renderer reads.
  confutils_narrow_terminal_width {.intdefine.} = 36
    ## The same define confutils' renderer reads.
  descPadding = 6
  minNameWidth = 24 - descPadding
  noColors = defined(confutils_no_colors)

type
  ClassicParamKind* = enum
    ## How the classic renderer sees a parameter (confutils' field kinds).
    ckSwitch ## a flag: a plain field
    ckArg    ## a positional: an ``{.argument.}`` field
    ckRest   ## a ``rest`` positional: a ``{.restOfArgs.}`` field

  ClassicParam* = object
    ## A parameter as confutils' renderer sees the field it stands for.
    id*: int
      ## The parameter id in the grammar.
    kind*: ClassicParamKind
    name*: string
      ## The long flag without ``--``, or a positional's name.
    abbr*: string
      ## The abbreviation: the ``short`` letter, or a long ``alias``
      ## without its dashes; empty when there is none.
    desc*, longDesc*, typeName*: string
    hidden*: bool
    defaultText*: string
      ## What help shows as the default; empty for none.

  ClassicCommand* = object
    ## A command as confutils' renderer sees it.
    command*: int
      ## The command's index in the grammar.
    name*, desc*: string
    params*: seq[ClassicParam]
      ## The command's own parameters, in declaration order.
    hasSubcommands*: bool
      ## Whether the command has a ``{.command.}`` discriminator, after
      ## ``params``: a ``call:`` or a listed ``subcmd``.
    subcommands*: seq[ClassicCommand]
      ## The discriminator's values: the ``call:`` first, when there is one
      ## (``defaultSubcommand`` is then 0), then every listed ``subcmd``.
    defaultSubcommand*: int
      ## The index in ``subcommands`` of the ``call:``, or -1.

func classicParam(g: CliGrammar; id: int): ClassicParam =
  let p = g.params[id]
  result.id = id
  result.kind = if p.kind == cpkFlag: ckSwitch
                elif p.rest: ckRest
                else: ckArg
  result.name = if p.kind == cpkFlag: cliLongName(p) else: p.name
  if p.short != '\0':
    result.abbr = $p.short
  elif p.kind == cpkFlag and p.alias.len > 0:
    result.abbr = p.alias.strip(trailing = false, chars = {'-'})
  result.desc = p.help
  result.longDesc = p.longHelp
  result.typeName = p.nimType
  result.hidden = p.visibility != cvShown
  result.defaultText = p.defaultText

func cliClassicCommand*(g: CliGrammar; command: int): ClassicCommand =
  ## The command ``command`` of ``g`` (an index into ``g.commands``) as
  ## confutils' renderer sees the equivalent type (see the module
  ## documentation), with its subcommands, recursively.
  let c = g.commands[command]
  result.command = command
  result.name = c.name
  if command != 0:
    result.desc = c.help
  for id in c.ownParams:
    if csCli in g.params[id].sources:
      result.params.add(classicParam(g, id))
  result.defaultSubcommand = -1
  if c.callChild >= 0:
    result.defaultSubcommand = 0
    result.subcommands.add(cliClassicCommand(g, c.callChild))
  for child in c.children:
    if g.commands[child].visibility != cvHidden:
      result.subcommands.add(cliClassicCommand(g, child))
  result.hasSubcommands = result.subcommands.len > 0

func cliClassicTerminalWidth*(): int =
  ## The width confutils' help wraps to: ``terminalWidth()`` (``COLUMNS``,
  ## then the terminal), or no limit when it cannot be determined.
  {.cast(noSideEffect).}:
    try:
      terminalWidth()
    except ValueError:
      int.high

# ---------------------------------------------------------------------------
# The renderer. Every ``put`` below is one ``helpOutput`` call of confutils'
# renderer, with the same arguments; ``reset`` is whether that call has an
# argument that is not a string literal, for which Nim's ``styledWrite``
# resets the attributes after writing.
# ---------------------------------------------------------------------------

type
  Renderer = object
    output: string
    namesWidth: int
    hasAbbrs: bool
    width: int

const
  resetCode = ansiResetCode

when noColors:
  const
    bright = ""
    section = ""
    commandColor = ""
    optionColor = ""
else:
  const
    bright = ansiStyleCode(styleBright)
    section = ansiForegroundColorCode(fgYellow)
    commandColor = ansiForegroundColorCode(fgCyan)
    optionColor = ansiForegroundColorCode(fgBlue)

func put(r: var Renderer; parts: varargs[string]; reset: bool) =
  for part in parts:
    r.output.add(part)
  if reset:
    r.output.add(resetCode)

func padding(output: string; desiredWidth: int): string =
  spaces(max(desiredWidth - output.len, 0))

func hasOpts(cmd: ClassicCommand): bool =
  for p in cmd.params:
    if p.kind == ckSwitch and not p.hidden:
      return true

func trailingArgs(cmd: ClassicCommand): seq[ClassicParam] =
  ## The positionals confutils lists: the run of them that ends the
  ## command's fields (none when a subcommand discriminator ends them).
  if cmd.hasSubcommands:
    return
  var first = cmd.params.len
  while first > 0 and cmd.params[first - 1].kind == ckArg:
    dec first
  cmd.params[first .. ^1]

func maxNameLen(cmd: ClassicCommand): int =
  for p in cmd.params:
    if p.kind != ckArg:
      result = max(result, p.name.len)

func anyAbbrs(cmd: ClassicCommand): bool =
  for p in cmd.params:
    if p.kind != ckArg and p.abbr.len > 0:
      return true

func writeDesc(r: var Renderer; desc, defaultValue: string) =
  const descSpacing = "  "
  let
    descIndent = 5 + r.namesWidth + descSpacing.len
    remainingColumns = r.width - descIndent
    defaultValSuffix = if defaultValue.len == 0: ""
                       else: " [=" & defaultValue & "]"
    fullDesc = desc & defaultValSuffix & "."
  if remainingColumns < confutils_narrow_terminal_width:
    r.put("\p ", wrapWords(fullDesc, r.width - 2, newLine = "\p "),
          reset = true)
  else:
    let wrappingWidth = min(remainingColumns, confutils_description_width)
    r.put(descSpacing, wrapWords(fullDesc, wrappingWidth,
                                 newLine = "\p" & spaces(descIndent)),
          reset = true)

func writeLongDesc(r: var Renderer; desc: string) =
  for line in split(desc, {'\n', '\r'}):
    if line.len > 0:
      r.put("\p", reset = false)
      r.put(padding("", 5 + r.namesWidth), reset = true)
      r.writeDesc(line, "")

func describeInvocation(r: var Renderer; cmd: ClassicCommand;
                        invocation: string) =
  r.put(bright, "\p", commandColor, invocation, reset = true)
  let args = trailingArgs(cmd)
  if cmd.hasOpts:
    r.put(" [OPTIONS]...", reset = false)
  if cmd.hasSubcommands:
    r.put(" command", reset = false)
  for arg in args:
    r.put(" <", arg.name, ">", reset = true)
  r.put("\p", reset = false)
  if cmd.desc.len > 0:
    r.put("\p", cmd.desc, ".\p", reset = true)
  var argsSectionStarted = false
  for arg in args:
    if arg.desc.len > 0:
      if not argsSectionStarted:
        r.put("\p", reset = false)
        argsSectionStarted = true
      let cliArg = " <" & arg.name & ">"
      r.put(optionColor, bright, cliArg, reset = true)
      r.put(padding(cliArg, 6 + r.namesWidth), reset = true)
      r.writeDesc(arg.desc, arg.defaultText)
      r.writeLongDesc(arg.longDesc)
      r.put("\p", reset = false)

func describeOptions(r: var Renderer; cmd: ClassicCommand;
                     invocation: string; heading = true) =
  if cmd.hasOpts:
    if heading:
      r.put("\pThe following options are available:\p\p", reset = false)
    for p in cmd.params:
      if p.kind == ckArg or p.hidden:
        continue
      r.put(" ", reset = false)
      if p.abbr.len > 0:
        let dashes = if p.abbr.len > 1: "--" else: "-"
        r.put(optionColor, bright, dashes, p.abbr, ", ", reset = true)
      elif r.hasAbbrs:
        r.put("    ", reset = false)
      if p.name.len > 0:
        let switch = "--" & p.name
        r.put(optionColor, bright, switch, padding(switch, r.namesWidth),
              reset = true)
      else:
        r.put(spaces(2 + r.namesWidth), reset = true)
      if p.desc.len > 0:
        r.writeDesc(p.desc.replace("%t", p.typeName), p.defaultText)
        r.writeLongDesc(p.longDesc)
      r.put("\p", reset = false)
  if cmd.hasSubcommands:
    if cmd.defaultSubcommand != -1:
      r.describeOptions(cmd.subcommands[cmd.defaultSubcommand], invocation,
                        heading = false)
    r.put(section, "\pAvailable sub-commands:\p", reset = true)
    for i, sub in cmd.subcommands:
      if i != cmd.defaultSubcommand:
        let subInvocation = invocation & " " & sub.name
        r.describeInvocation(sub, subInvocation)
        r.describeOptions(sub, subInvocation)

proc cliClassicHelp*(g: CliGrammar; commandPath: openArray[string] = [];
                     programName = ""; copyrightBanner = "";
                     width = cliClassicTerminalWidth()): string {.
    raises: [CliUsageError].} =
  ## The help confutils prints for the command reached by the subcommand
  ## words ``commandPath`` (matched as the parser matches them) of the type
  ## equivalent to the description of ``g`` (see the module documentation).
  ## ``programName`` (``g.program`` when empty) starts the usage line,
  ## followed by the commands' names; ``copyrightBanner``, when not empty,
  ## comes first, as ``load(copyrightBanner = ...)`` puts it. Raises
  ## ``CliUsageError`` for a word that names no subcommand.
  let command = cliHelpCommand(g, commandPath, g.program)
  let cmd = cliClassicCommand(g, command)
  var r = Renderer(width: width, hasAbbrs: anyAbbrs(cmd),
                   namesWidth: min(minNameWidth, maxNameLen(cmd)) +
                     descPadding)
  if copyrightBanner.len > 0:
    r.put(copyrightBanner, "\p\p", reset = true)
  var invocation = if programName.len > 0: programName else: g.program
  var k = command
  var names: seq[string] = @[]
  while k > 0:
    names.add(g.commands[k].name)
    k = g.commands[k].parent
  for i in countdown(names.high, 0):
    invocation.add(" " & names[i])
  r.put(section, "Usage: \p", reset = true)
  r.describeInvocation(cmd, invocation)
  r.describeOptions(cmd, invocation)
  r.put("\p", reset = false)
  r.output

proc classicGrammarOf[T](t: typedesc[T]): CliGrammar =
  ## The grammar of a description, with the ``defaultValueDesc`` texts
  ## ``confutils/clispec_config`` records applied when ``T`` has them.
  mixin cliGrammar, cliClassicGrammar
  when compiles(cliClassicGrammar(T)):
    cliClassicGrammar(T)
  else:
    cliGrammar(T)

proc cliClassicHelp*[T](t: typedesc[T]; commandPath: openArray[string] = [];
                        programName = ""; copyrightBanner = "";
                        width = cliClassicTerminalWidth()): string {.
    raises: [CliUsageError].} =
  ## ``cliClassicHelp`` over the grammar of the description ``T``
  ## (``cliProgram`` / ``cliConfiguration``), with the ``defaultValueDesc``
  ## texts of a ``cliConfiguration`` description.
  cliClassicHelp(classicGrammarOf(T), commandPath, programName,
                 copyrightBanner, width)

proc showClassicHelp*(g: CliGrammar; commandPath: openArray[string] = [];
                      programName = ""; copyrightBanner = "";
                      width = cliClassicTerminalWidth()) {.
    raises: [CliUsageError, IOError].} =
  ## Writes ``cliClassicHelp`` to stdout, as confutils' ``load`` does when
  ## help is asked for (it then quits; this returns).
  stdout.write(cliClassicHelp(g, commandPath, programName, copyrightBanner,
                              width))
  stdout.flushFile()

proc showClassicHelp*[T](t: typedesc[T]; commandPath: openArray[string] = [];
                         programName = ""; copyrightBanner = "";
                         width = cliClassicTerminalWidth()) {.
    raises: [CliUsageError, IOError].} =
  ## ``showClassicHelp`` over the grammar of the description ``T``.
  showClassicHelp(classicGrammarOf(T), commandPath, programName,
                  copyrightBanner, width)

func cliApplyDefaultValueDescs*(g: var CliGrammar;
                                descs: openArray[tuple[id: int,
                                                       text: string]]) =
  ## Replaces the default text of parameter ``id`` with ``text`` for each
  ## entry, as ``{.defaultValueDesc.}`` replaces it in confutils: what the
  ## classic help and the runtime surface show. ``hasDefault`` is unchanged.
  for d in descs:
    g.params[d.id].defaultText = d.text
