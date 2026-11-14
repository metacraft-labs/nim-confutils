# nim-confutils
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Typed compile-time options read from `-d:` defines.
##
## A library that is configured with `-d:name=value` switches usually reads
## each one as a string (`{.strdefine.}`) and then turns it into a `bool` or
## an enum by hand, with its own list of accepted spellings and its own error
## message. The attribute macros in this module do that in one place:
##
## .. code-block:: nim
##   import confutils/defines
##
##   type LogLevel = enum TRACE, DEBUG, INFO
##
##   const
##     mylib_log_level {.enumDefine.}: LogLevel = INFO  # -d:mylib_log_level=debug
##     mylib_stack_traces {.flagDefine.} = false        # -d:mylib_stack_traces=on
##
## Each constant keeps its declared default when the define is absent, and
## otherwise holds the parsed value. An unrecognised value is a compile error
## that names the option, the value and the values it accepts.
##
## - `{.flagDefine.}` accepts the spellings in `truthySpellings` and
##   `falsySpellings` in any letter case. A bare `-d:name` (which the compiler
##   passes as `true`) is truthy. (It is not called `boolDefine`: Nim
##   compares identifiers ignoring case after the first letter, so that name
##   is the built-in `{.booldefine.}`, which accepts fewer spellings.)
## - `{.enumDefine.}` accepts each value's name and, for an enum with string
##   values, each value's string, compared ignoring letter case and
##   underscores (`strutils.cmpIgnoreStyle`); when two values match, the one
##   declared first wins. `{.enumDefine(offValue = X).}` also maps every
##   falsy spelling to `X`, after the enum's own names were tried, so an
##   enum value spelled `none` keeps its meaning.
## - The define's name is the constant's name. Another one can be given as
##   the first argument, `{.flagDefine("mylib.traces").}` or
##   `{.enumDefine(name = "mylib.level").}`.
##
## The constant may be exported (`name* {.flagDefine.} = false`) and may carry
## other pragmas. `{.enumDefine.}` takes the enum type from the declaration,
## or from the default value when no type is written.
##
## The parsing functions are exported too, for run-time use (an environment
## variable, a configuration value) with the same spellings.

import std/[enumutils, macros, options, strutils]

export options

const
  truthySpellings* = ["yes", "1", "on", "true"]
    ## The values `{.flagDefine.}` and `parseFlagValue` read as `true`
    ## (letter case is ignored).
  falsySpellings* = ["no", "0", "off", "false", "none"]
    ## The values `{.flagDefine.}` and `parseFlagValue` read as `false`
    ## (letter case is ignored).

  unsetDefine = "\0confutils: define not given"
    # The value of the hidden `{.strdefine.}` when no `-d:` switch sets it;
    # a command-line define cannot contain a NUL byte.

func parseFlagValue*(value: string): Option[bool] =
  ## `some(true)` for a truthy spelling, `some(false)` for a falsy one and
  ## `none(bool)` for anything else. Letter case is ignored.
  let lowered = value.toLowerAscii
  if lowered in truthySpellings: some(true)
  elif lowered in falsySpellings: some(false)
  else: none(bool)

func isFalsyValue*(value: string): bool =
  ## Whether `value` is one of `falsySpellings`, in any letter case.
  value.toLowerAscii in falsySpellings

iterator enumValues[E: enum](T: typedesc[E]): E =
  # `for e in E` would look up `items` where the generic is instantiated,
  # which for an enum with holes needs `std/enumutils` in the caller's scope.
  when E is Ordinal:
    for e in low(E) .. high(E): yield e
  else:
    for e in enumutils.items(E): yield e

func parseEnumValue*[E: enum](value: string): Option[E] =
  ## The first value of `E`, in declaration order, whose name or string value
  ## equals `value` when letter case and underscores are ignored.
  for e in enumValues(E):
    if cmpIgnoreStyle(value, symbolName(e)) == 0 or
       cmpIgnoreStyle(value, $e) == 0:
      return some(e)
  none(E)

func enumValueSpellings*[E: enum](): seq[string] =
  ## The values `parseEnumValue[E]` accepts, as listed in an error message:
  ## each value's string, followed by its name in parentheses when the two
  ## differ.
  for e in enumValues(E):
    if $e == symbolName(e): result.add($e)
    else: result.add($e & " (" & symbolName(e) & ")")

func defineErrorMessage*(name, value: string;
                         allowed: openArray[string]; note = ""): string =
  ## The compile error for an unrecognised value of the option `name`.
  result = "invalid value '" & value & "' for the compile-time option '" &
    name & "' (-d:" & name & "=" & value & "); allowed values: " &
    allowed.join(", ")
  if note.len > 0:
    result.add(" (" & note & ")")

func flagDefineError*(name, value: string): string =
  ## The compile error `{.flagDefine.}` reports for an unrecognised value.
  defineErrorMessage(name, value, @truthySpellings & @falsySpellings,
    "in any letter case; a bare -d:" & name & " means true")

func enumDefineError*[E: enum](name, value: string;
                               falsyMapped = false): string =
  ## The compile error `{.enumDefine.}` reports for an unrecognised value.
  var note = "letter case and underscores are ignored"
  if falsyMapped:
    note.add("; or one of " & falsySpellings.join(", "))
  defineErrorMessage(name, value, enumValueSpellings[E](), note)

type DefineArgs = object
  defineName: string
  offValue: NimNode
  constDef: NimNode

proc constIdent(nameNode: NimNode): NimNode =
  case nameNode.kind
  of nnkIdent, nnkSym: nameNode
  of nnkPostfix: constIdent(nameNode[1])
  of nnkPragmaExpr: constIdent(nameNode[0])
  of nnkAccQuoted:
    var name = ""
    for part in nameNode: name.add(part.strVal)
    ident(name)
  else:
    error("cannot read the constant's name", nameNode)

proc parseDefineArgs(macroName: string; args: NimNode;
                     acceptsOffValue: bool): DefineArgs =
  if args.len == 0:
    error("{." & macroName & ".} is written as a pragma on a constant")
  var section = args[^1]
  if section.kind == nnkConstSection and section.len == 1:
    section = section[0]
  if section.kind != nnkConstDef:
    error("{." & macroName & ".} applies to a `const` declaration, " &
          "as in `const name {." & macroName & ".} = default`", section)
  result.constDef = section
  for i in 0 ..< args.len - 1:
    let arg = args[i]
    if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and i == 0:
      result.defineName = arg.strVal
    elif arg.kind == nnkExprEqExpr and arg[0].eqIdent("name") and
         arg[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      result.defineName = arg[1].strVal
    elif acceptsOffValue and arg.kind == nnkExprEqExpr and
         arg[0].eqIdent("offValue"):
      result.offValue = arg[1]
    else:
      error("{." & macroName & ".} takes the define's name as a string" &
            (if acceptsOffValue: " and `offValue = <enum value>`" else: "") &
            ", not `" & arg.repr & "`", arg)
  if result.defineName.len == 0:
    result.defineName = $constIdent(section[0])
  if section[2].kind == nnkEmpty:
    error("{." & macroName & ".} needs a default value", section)

proc withLineInfo(n, info: NimNode): NimNode =
  n.copyLineInfo(info)
  for child in n:
    discard withLineInfo(child, info)
  n

proc hiddenDefine(args: DefineArgs): NimNode =
  genSym(nskConst, $constIdent(args.constDef[0]) & "Define")

proc defineSection(args: DefineArgs; raw, valueType, parsed: NimNode): NimNode =
  ## const
  ##   raw {.strdefine: "<define>".} = unsetDefine
  ##   <declared name>: <type> = when raw == unsetDefine: <default>
  ##                             else: <parsed>
  let
    defineName = newLit(args.defineName)
    unset = newLit(unsetDefine)
    default = args.constDef[2]
  result = quote do:
    const
      `raw` {.strdefine: `defineName`.} = `unset`
      x: `valueType` =
        when `raw` == `unset`: `default`
        else: `parsed`
  result[1][0] = args.constDef[0]

macro flagDefine*(args: varargs[untyped]): untyped =
  ## `const name {.flagDefine.} = default`: a `bool` constant set by
  ## `-d:name=<value>` with a value from `truthySpellings` or `falsySpellings`
  ## (any letter case), or by a bare `-d:name`. `{.flagDefine("other").}`
  ## reads `-d:other` instead.
  let a = parseDefineArgs("flagDefine", args, acceptsOffValue = false)
  let valueType =
    if a.constDef[1].kind == nnkEmpty: ident("bool") else: a.constDef[1]
  let
    rawValue = hiddenDefine(a)
    defineName = newLit(a.defineName)
    parseProc = bindSym("parseFlagValue")
    errorProc = bindSym("flagDefineError")
  let failure = withLineInfo(
    nnkPragma.newTree(nnkExprColonExpr.newTree(
      ident("error"), newCall(errorProc, defineName, rawValue))),
    a.constDef)
  let
    isSomeProc = bindSym("isSome")
    getProc = bindSym("get")
  let parsed = quote do:
    when `isSomeProc`(`parseProc`(`rawValue`)):
      `getProc`(`parseProc`(`rawValue`))
    else:
      `failure`
  defineSection(a, rawValue, valueType, parsed)

macro enumDefine*(args: varargs[untyped]): untyped =
  ## `const name {.enumDefine.}: MyEnum = default`: an enum constant set by
  ## `-d:name=<value>`, where the value is one of the enum's names or string
  ## values, compared ignoring letter case and underscores.
  ## `{.enumDefine("other").}` reads `-d:other` instead;
  ## `{.enumDefine(offValue = X).}` also reads every falsy spelling as `X`.
  let a = parseDefineArgs("enumDefine", args, acceptsOffValue = true)
  let valueType =
    if a.constDef[1].kind == nnkEmpty: newCall("typeof", a.constDef[2])
    else: a.constDef[1]
  let
    rawValue = hiddenDefine(a)
    defineName = newLit(a.defineName)
    parseProc = bindSym("parseEnumValue")
    falsyProc = bindSym("isFalsyValue")
    errorProc = bindSym("enumDefineError")
    falsyMapped = newLit(a.offValue != nil)
  let failure = withLineInfo(
    nnkPragma.newTree(nnkExprColonExpr.newTree(
      ident("error"),
      newCall(nnkBracketExpr.newTree(errorProc, valueType),
              defineName, rawValue, falsyMapped))),
    a.constDef)
  let parseCall = newCall(nnkBracketExpr.newTree(parseProc, valueType),
                          rawValue)
  var parsed = nnkWhenStmt.newTree(
    nnkElifBranch.newTree(newCall(bindSym("isSome"), parseCall),
                          newCall(bindSym("get"), parseCall.copyNimTree)))
  if a.offValue != nil:
    parsed.add nnkElifBranch.newTree(newCall(falsyProc, rawValue),
                                     a.offValue)
  parsed.add nnkElse.newTree(failure)
  defineSection(a, rawValue, valueType, parsed)
