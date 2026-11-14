## TOML configuration files, read with
## `nim-toml-serialization <https://github.com/status-im/nim-toml-serialization>`_.
##
## This module is the TOML format adapter of ``confutils/layers/sources``.
## ``confutils/clispec_config`` does not import it: a program that reads
## TOML configuration files imports it (``import
## confutils/layers/toml_source``) and requires ``toml_serialization``; a
## program that does not pays for no serialization library.
##
## .. code-block:: nim
##   import confutils/clispec_config, confutils/layers/toml_source
##
##   let conf = Tool.load(argv, CliSources(format: tomlCliFormat(),
##     layers: @[CliLayer(name: "user",
##       path: getConfigDir() / "tool" / "config.toml")],
##     env: cliProcessEnv()))
##
## What it accepts
## ===============
##
## Any TOML 1.0 document that the pinned ``toml_serialization`` accepts: the
## whole file is parsed by its ``parseToml`` first, so a syntax error, a key
## defined twice or a table redefined is reported with the parser's own
## message and position. A second pass over the same text records the line
## of every key, which errors and origins name. Tables (``[build]``, dotted
## keys, inline tables) are flattened into one entry per value; an array of
## tables (``[[name]]``) is one entry of kind ``ccvTableArray``, which no
## parameter accepts, so outside the ``extensions`` table it is an error
## naming its key. That holds for an array of tables nested inside another
## (``[[a.b]]`` under ``[[a]]``) too: ``parseToml`` accepts the nesting, and
## both arrays are reported as entries of their own, so outside
## ``extensions`` the first one is the error.
##
## A layer's ``path`` is used as given: ``~`` and environment variables are
## not expanded (the program builds the path, e.g. with ``getConfigDir()``).
##
## Values are read verbatim. Integers are 64-bit, as TOML defines them.

import std/strutils

import faststreams/inputs
import toml_serialization/[lexer, types]

import ./sources

export sources

func valueOf(v: TomlValueRef): CliConfigValue =
  case v.kind
  of TomlKind.String:
    CliConfigValue(kind: ccvString, text: v.stringVal)
  of TomlKind.Int:
    CliConfigValue(kind: ccvInteger, text: $v.intVal)
  of TomlKind.Float:
    CliConfigValue(kind: ccvFloat, text: $v.floatVal)
  of TomlKind.Bool:
    CliConfigValue(kind: ccvBool, text: (if v.boolVal: "true" else: "false"))
  of TomlKind.DateTime:
    CliConfigValue(kind: ccvDateTime, text: "<date-time>")
  of TomlKind.Array:
    var r = CliConfigValue(kind: ccvArray)
    for item in v.arrayVal:
      r.items.add(valueOf(item))
    r
  of TomlKind.Table, TomlKind.InlineTable:
    CliConfigValue(kind: ccvTable)
  of TomlKind.Tables:
    CliConfigValue(kind: ccvTableArray)

proc flatten(key: seq[string]; v: TomlValueRef; line: int;
             entries: var seq[CliConfigEntry]) =
  ## An inline table's values become entries of their own, as the same
  ## keys written as a table would.
  if v.kind in {TomlKind.Table, TomlKind.InlineTable}:
    for name, inner in v.tableVal[]:
      flatten(key & @[name], inner, line, entries)
  else:
    entries.add(CliConfigEntry(key: key, value: valueOf(v), line: line))

proc syntaxError(path: string; line: int; msg: string): ref CliConfigError =
  # The parser's own message starts with its "(line, col)"; keep it, it
  # carries the column.
  newCliConfigError(cfeSyntax, path, line, detail = msg.strip())

proc parseTomlConfig*(path, content: string): CliConfigDocument {.
    gcsafe, raises: [CliConfigError].} =
  ## The TOML ``CliConfigParser``: ``content`` (the text of the file at
  ## ``path``) as a flat list of entries, each with the line its key is
  ## written on.
  # Pass 1: the whole document through toml_serialization's own parser,
  # which checks everything TOML requires (duplicate keys and tables
  # included) but keeps no positions.
  block validate:
    var lex = TomlLexer.init(unsafeMemoryInput(content))
    try:
      discard parseToml(lex)
    except CatchableError as e:
      raise syntaxError(path, lex.line, e.msg)
  # Pass 2: walk the same text, recording where each key is written.
  var lex = TomlLexer.init(unsafeMemoryInput(content))
  var table: seq[string] = @[]
  var inTableArray = false
  try:
    while true:
      let next = lex.nonws(skipLf)
      case next
      of EOF:
        break
      of '[':
        let line = lex.line
        discard lex.next()
        var names: seq[string] = @[]
        let bracket = scanTableName(lex, names)
        table = names
        inTableArray = bracket == BracketType.double
        if inTableArray:
          # Its body belongs to one element of the array; the array as a
          # whole is reported once, at its first header.
          var seen = false
          for e in result.entries:
            if e.key == names and e.value.kind == ccvTableArray:
              seen = true
          if not seen:
            result.entries.add(CliConfigEntry(key: names,
              value: CliConfigValue(kind: ccvTableArray), line: line))
      else:
        let line = lex.line
        var keys: seq[string] = @[]
        scanKey(lex, keys)
        if lex.next() != '=':
          raise syntaxError(path, lex.line, "expected '=' after a key")
        var value: TomlValueRef
        parseValue(lex, value)
        if not inTableArray:
          flatten(table & keys, value, line, result.entries)
        checkEol(lex, line)
  except CliConfigError as e:
    raise e
  except CatchableError as e:
    raise syntaxError(path, lex.line, e.msg)

proc tomlCliFormat*(): CliConfigFormat =
  ## The TOML format, for ``CliSources.format``.
  CliConfigFormat(name: "toml", parse: parseTomlConfig)
