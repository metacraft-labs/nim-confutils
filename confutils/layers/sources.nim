## Configuration files and the environment as sources of parameter values.
##
## A program described in clispec has parameters that can be supplied by
## three kinds of source, from the lowest precedence to the highest:
## configuration files, in the layers the program declares (lowest first),
## environment variables, and the command line. This module reads the first
## two into clispec *candidates*, recording where each came from as a
## ``CliSite`` (``confutils/layers/origins``); ``confutils/layers/merge``
## merges them with the command line's, which clispec's parser reads.
##
## What a parameter accepts from each source is declared in its clispec
## description (``env``, ``key``, ``sources``, ``configSchema``, the naming
## conventions); this module reads those declarations from the description's
## grammar.
##
## Layers belong to the program
## ============================
##
## The library does not decide which configuration files exist. A program lists
## its layers in a ``CliSources``, lowest precedence first, each with a name
## (``"system"``, ``"user"``, ``"project"``), a path and two flags:
## ``binding`` (every value the layer sets is *enforced*: no other source,
## the environment and the command line included, can override it) and
## ``required`` (a missing file is an error rather than an absent layer).
## The environment is passed in as a table, so nothing here reads the
## process's environment unless the program asks (``cliProcessEnv``).
##
## Configuration files
## ===================
##
## A file is read by a *format adapter* (``CliConfigFormat``), which turns
## its text into a flat list of entries: one per value, keyed by the full
## path of its key's segments (``[build]`` / ``jobs = 4`` and
## ``build.jobs = 4`` are both the entry ``build.jobs``), with the line it was
## written on. The adapter knows the format's syntax and nothing about the
## program. ``confutils/layers/toml_source`` is the TOML adapter; an adapter for
## another format implements the same small interface (see
## ``CliConfigParser``).
##
## The program's schema, generated from its description, is then applied
## to the entries, the same way for every format:
##
## * the file must carry a top-level ``schema`` string equal to the
##   identifier the description declares (``configSchema "tool.config.v1"``
##   under ``cli:``);
## * every other key must be the configuration key of a parameter, as the
##   layer's source spells it (see clispec's ``clispec/model``, "Names and
##   configuration keys" and "Naming conventions": a layer whose name, or
##   else whose format's name, is a file source the description declares
##   uses that source's spelling, any other layer the ``file`` source's),
##   except keys under a
##   top-level ``extensions`` table, which are the escape hatch for data the
##   program does not define and are never read;
## * each value must have its parameter's type (``CliConfigType``): a
##   string, an integer, a float (an integer is accepted too) or a bool, and
##   an array of these for a list parameter. A counted flag takes an
##   integer.
##
## An unknown key, a missing or wrong ``schema`` or a value of the wrong
## type is a ``CliConfigError`` naming the file, the line and the key.
## Values are read verbatim: nothing is interpolated or expanded.
##
## The environment
## ===============
##
## A parameter reads exactly the variables its ``env`` lists; the first one
## present in the table supplies the value, as text, converted like a
## command-line value. A list parameter's variable is one element, or, when
## the parameter declares a ``separator``, a delimited list of them. A
## variable that is present but empty supplies the empty string.

import std/[envvars, json, os, strutils, tables]

import clispec/[model, grammar, candidates]

import ./origins

export tables, origins

type
  CliConfigErrorKind* = enum
    ## The kinds of configuration-file error. Each has one wording
    ## (``cliConfigErrorMessage``), and every wording names the file, and
    ## the line and key when there is one.
    cfeUnreadable = "unreadable file"
      ## A layer the program requires is missing, or a file cannot be read.
    cfeSyntax = "syntax error"
      ## The format adapter rejected the file (``detail`` is its message).
    cfeMissingSchema = "missing schema"
      ## The file has no top-level ``schema`` string.
    cfeWrongSchema = "wrong schema"
      ## The file's ``schema`` is not the identifier the program declares.
    cfeUnknownKey = "unknown key"
      ## A key that names no parameter (and is not under ``extensions``).
    cfeWrongType = "wrong type"
      ## A value of the wrong type for its key (``expected`` says which).
    cfeNoSchemaDeclared = "no schema declared"
      ## The program loads a configuration file but its description
      ## declares no ``configSchema``, so no file can be valid.
    cfeNoFormat = "no format"
      ## The program declares layers but no format to read them with.

  CliConfigError* = object of CatchableError
    ## A configuration file that cannot be accepted. ``msg`` is
    ## ``cliConfigErrorMessage`` of the other fields.
    kind*: CliConfigErrorKind
    path*: string
      ## The file.
    line*: int
      ## The line the error is about; 0 when it is about the whole file.
    key*: string
      ## The key the error is about, as written in the file, or empty.
    layer*: string
      ## The name of the layer the file was loaded as.
    expected*: string
      ## What would have been accepted (``cfeWrongType``,
      ## ``cfeWrongSchema``).
    detail*: string
      ## The format's own message (``cfeSyntax``, ``cfeUnreadable``), or
      ## the value found (``cfeWrongSchema``, ``cfeWrongType``).

func cliConfigErrorMessage*(kind: CliConfigErrorKind; path: string;
                            line: int; key, layer, expected,
                            detail: string): string =
  ## The one wording of each kind of configuration-file error:
  ## ``<file>[:<line>]: <what> (layer '<name>')``.
  let at = (if path.len > 0: path else: "<no file>") &
    (if line > 0: ":" & $line else: "")
  let what = case kind
    of cfeUnreadable: "cannot be read: " & detail
    of cfeSyntax: "is not valid: " & detail
    of cfeMissingSchema:
      "has no top-level `schema` string; expected schema = \"" &
        expected & "\""
    of cfeWrongSchema:
      "declares schema \"" & detail & "\"; expected \"" & expected & "\""
    of cfeUnknownKey: "unknown key '" & key & "'"
    of cfeWrongType:
      "key '" & key & "' has " & detail & "; expected " & expected
    of cfeNoSchemaDeclared:
      "cannot be loaded: the program declares no configSchema"
    of cfeNoFormat:
      "cannot be loaded: no configuration format was given"
  at & ": " & what & (if layer.len > 0: " (layer '" & layer & "')" else: "")

proc newCliConfigError*(kind: CliConfigErrorKind; path: string; line = 0;
                        key = ""; layer = ""; expected = "";
                        detail = ""): ref CliConfigError =
  ## A configuration-file error with its message filled in.
  result = (ref CliConfigError)(kind: kind, path: path, line: line, key: key,
    layer: layer, expected: expected, detail: detail)
  result.msg = cliConfigErrorMessage(kind, path, line, key, layer, expected,
    detail)

type
  CliConfigValueKind* = enum
    ## The kind of a value a format adapter read.
    ccvString = "a string"
    ccvInteger = "an integer"
    ccvFloat = "a float"
    ccvBool = "a bool"
    ccvDateTime = "a date-time"
    ccvArray = "an array"
    ccvTable = "a table"
      ## A table inside an array (tables elsewhere are flattened into
      ## entries).
    ccvTableArray = "an array of tables"

  CliConfigValue* = object
    ## One value of a configuration file.
    kind*: CliConfigValueKind
    text*: string
      ## A scalar's value as text: a string's content, an integer in
      ## decimal, a float as Nim prints it, ``true`` or ``false``, a
      ## date-time as written.
    items*: seq[CliConfigValue]
      ## An array's elements.

  CliConfigEntry* = object
    ## One key of a configuration file with its value.
    key*: seq[string]
      ## The key's segments, from the top of the file (a table header's
      ## segments followed by the key's own).
    value*: CliConfigValue
    line*: int
      ## The line the key is written on (1-based).

  CliConfigDocument* = object
    ## What a format adapter read from a file.
    entries*: seq[CliConfigEntry]
      ## Every value, in file order. Tables (inline ones included) are
      ## flattened into their values; an array of tables is one entry of
      ## kind ``ccvTableArray`` on the line of its first header.

  CliConfigParser* = proc (path, content: string): CliConfigDocument {.
    gcsafe, raises: [CliConfigError].}
    ## A format adapter: reads ``content`` (the text of the file at
    ## ``path``) into a document, or raises a ``CliConfigError`` of kind
    ## ``cfeSyntax`` naming the file and the line. It checks the format's
    ## syntax only; the program's schema is applied afterwards.

  CliConfigFormat* = object
    ## A configuration-file format.
    name*: string
      ## The format's name (``"toml"``).
    parse*: CliConfigParser

  CliLayer* = object
    ## One configuration file a program reads.
    name*: string
      ## What origins and errors call the layer (``"user"``).
    path*: string
    binding*: bool
      ## Every value the layer sets is enforced: no other source can
      ## override it, and an attempt is recorded in the origin as ignored.
    required*: bool
      ## A missing file is an error; otherwise the layer is skipped.

  CliSources* = object
    ## Every source besides the command line, for one load.
    layers*: seq[CliLayer]
      ## Lowest precedence first.
    env*: Table[string, string]
      ## The environment: variable name to value.
    format*: CliConfigFormat
      ## How the layers' files are read.

  CliSourced* = object
    ## What the layers and the environment supply for one load.
    candidates*: seq[seq[CliCandidate]]
      ## Per parameter id, in the order the merge considers them: the
      ## layers lowest first, then the environment.
    sites*: seq[CliSite]
      ## Where each candidate came from: a candidate's ``site`` indexes this.

  CliConfigKey* = object
    ## One key of a program's configuration-file schema.
    key*: string
      ## The key in the file source the schema was made for.
    sourceKeys*: seq[CliSourceSpelling]
      ## The key in every file source: ``file`` first, then each named
      ## source the description declares.
    configType*: CliConfigType
    list*: bool
      ## The value is an array of ``configType``.
    param*: string
      ## The parameter's name.
    declaredIn*: seq[string]
      ## The path of the command that declares the parameter.
    help*: string

  CliConfigSchema* = object
    ## The schema of a program's configuration files, generated from its
    ## description.
    id*: string
      ## The identifier files declare in their ``schema`` string.
    source*: string
      ## The file source whose spelling ``keys[i].key`` uses: ``file``, or
      ## a named source.
    convention*: CliConvention
      ## That source's naming convention.
    conventions*: seq[CliSourceConvention]
      ## The convention of every source: ``cli``, ``file``, then the named
      ## file sources.
    keys*: seq[CliConfigKey]
      ## Every valid key, in declaration order.

const
  CliSchemaKey* = "schema"
    ## The top-level key every configuration file declares its schema in.
  CliExtensionsKey* = "extensions"
    ## The top-level table a program never reads: the escape hatch.

func keyText(segments: openArray[string]): string =
  ## A key as a message shows it: segments joined with ``.``, a segment
  ## that needs it quoted.
  for i, s in segments:
    if i > 0:
      result.add('.')
    var bare = s.len > 0
    for ch in s:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
        bare = false
    if bare: result.add(s) else: result.add(escape(s))

func keyIndex(segments: openArray[string]): string =
  ## A key's segments as one table key (segments may contain ``.``).
  segments.join("\0")

func cliConfigSchemaOf*(g: CliGrammar;
                        source = CliSourceFile): CliConfigSchema =
  ## The configuration-file schema of a grammar: every parameter that a file
  ## may supply, with its key and type. ``key`` is spelt as the file source
  ## ``source`` spells it (``file``, the default, or a named source the
  ## description declares; an undeclared name is read as ``file``, as a
  ## layer of that name would be); ``sourceKeys`` lists every source's
  ## spelling.
  result.id = g.configSchema
  result.source = if cliHasFileSource(g, source): source else: CliSourceFile
  result.convention = cliFileSourceConvention(g, result.source)
  result.conventions.add(CliSourceConvention(source: CliSourceCli,
    convention: g.flagConvention))
  result.conventions.add(CliSourceConvention(source: CliSourceFile,
    convention: g.keyStyle))
  for s in g.fileSources:
    result.conventions.add(s)
  for p in g.params:
    if p.configKey.len == 0 or csFile notin p.sources:
      continue
    var all = @[CliSourceSpelling(source: CliSourceFile,
      spelling: p.configKey)]
    for k in p.sourceKeys:
      all.add(k)
    result.keys.add(CliConfigKey(key: cliSourceKeyOf(p, result.source),
      sourceKeys: all, configType: p.configType,
      list: p.isList and not p.counted, param: p.name,
      declaredIn: p.declaredIn, help: p.help))

proc cliConfigSchemaJson*(s: CliConfigSchema): string =
  ## The schema as JSON, under the schema name ``clispec-config-schema/1``:
  ## ``{"schema", "id", "reserved": ["schema", "extensions"], "keys":
  ## [{"key", "type", "list", "parameter", "declaredIn", "help",
  ## "sourceKeys": {"file": ..., "<named source>": ...}}, ...], "source",
  ## "conventions": {"cli": ..., "file": ..., "<named source>": ...}}``.
  ## ``key`` is spelt as the file source ``source`` spells it;
  ## ``sourceKeys`` gives every file source's spelling and ``conventions``
  ## every source's naming convention. Within that name keys are only ever
  ## added.
  var keys = newJArray()
  for k in s.keys:
    var perSource = newJObject()
    for sk in k.sourceKeys:
      perSource[sk.source] = %sk.spelling
    keys.add(%*{"key": k.key, "type": $k.configType, "list": k.list,
      "parameter": k.param, "declaredIn": k.declaredIn, "help": k.help,
      "sourceKeys": perSource})
  var conventions = newJObject()
  for c in s.conventions:
    conventions[c.source] = %($c.convention)
  $(%*{"schema": "clispec-config-schema/1", "id": s.id,
    "reserved": [CliSchemaKey, CliExtensionsKey], "keys": keys,
    "source": (if s.source.len > 0: s.source else: CliSourceFile),
    "conventions": conventions})

func fits(v: CliConfigValue; t: CliConfigType): bool =
  case t
  of cctString: v.kind == ccvString
  of cctInteger: v.kind == ccvInteger
  of cctFloat: v.kind in {ccvFloat, ccvInteger}
  of cctBool: v.kind == ccvBool

func expectedText(t: CliConfigType; list: bool): string =
  let one = case t
    of cctString: "a string"
    of cctInteger: "an integer"
    of cctFloat: "a number"
    of cctBool: "true or false"
  if list: "an array of " & (case t
    of cctString: "strings"
    of cctInteger: "integers"
    of cctFloat: "numbers"
    of cctBool: "bools")
  else: one

func foundText(v: CliConfigValue): string =
  case v.kind
  of ccvString: "the string " & escape(v.text)
  of ccvInteger, ccvFloat, ccvBool, ccvDateTime: $v.kind & " " & v.text
  else: $v.kind

func cliLayerSource*(g: CliGrammar; layer: CliLayer;
                     format: CliConfigFormat): string =
  ## The file source whose spelling a layer's keys use: the named source
  ## that is the layer's name, else the one that is the format's name, else
  ## ``file``.
  if cliHasFileSource(g, layer.name): layer.name
  elif cliHasFileSource(g, format.name): format.name
  else: CliSourceFile

proc addCandidate(sourced: var CliSourced; id: int; c: CliCandidate;
                  site: CliSite) =
  var c = c
  c.site = sourced.sites.len
  c.described = $site
  sourced.sites.add(site)
  sourced.candidates[id].add(c)

proc cliLoadLayer*(g: CliGrammar; layer: CliLayer; index: int;
                   format: CliConfigFormat; sourced: var CliSourced) {.
    raises: [CliConfigError].} =
  ## Reads one layer's file and appends what it supplies to
  ## ``sourced`` (indexed by parameter id). A missing file is skipped
  ## unless the layer is ``required``. Raises ``CliConfigError`` for a file
  ## that cannot be read or does not fit the program's schema.
  if not fileExists(layer.path):
    if layer.required:
      raise newCliConfigError(cfeUnreadable, layer.path, layer = layer.name,
        detail = "no such file")
    return
  if g.configSchema.len == 0:
    raise newCliConfigError(cfeNoSchemaDeclared, layer.path,
      layer = layer.name)
  if format.parse.isNil:
    raise newCliConfigError(cfeNoFormat, layer.path, layer = layer.name)
  var content: string
  try:
    content = readFile(layer.path)
  except IOError as e:
    raise newCliConfigError(cfeUnreadable, layer.path, layer = layer.name,
      detail = e.msg)
  var doc: CliConfigDocument
  try:
    doc = format.parse(layer.path, content)
  except CliConfigError as e:
    # The adapter does not know the layer's name; add it.
    raise newCliConfigError(e.kind, (if e.path.len > 0: e.path
      else: layer.path), e.line, e.key, layer.name, e.expected, e.detail)

  # The keys as this layer's source spells them: a key spelt in another
  # source's convention is unknown here.
  let source = cliLayerSource(g, layer, format)
  var byKey = initTable[string, int]()
  for id, p in g.params:
    if p.configKey.len > 0 and csFile in p.sources:
      byKey[keyIndex(cliSourceKeyOf(p, source).split('.'))] = id

  var schemaSeen = false
  for e in doc.entries:
    if e.key == @[CliSchemaKey]:
      schemaSeen = true
      if e.value.kind != ccvString or e.value.text != g.configSchema:
        raise newCliConfigError(cfeWrongSchema, layer.path, e.line,
          CliSchemaKey, layer.name, g.configSchema,
          (if e.value.kind == ccvString: e.value.text
           else: foundText(e.value)))
  if not schemaSeen:
    raise newCliConfigError(cfeMissingSchema, layer.path, layer = layer.name,
      expected = g.configSchema)

  for e in doc.entries:
    if e.key.len == 0 or e.key == @[CliSchemaKey] or
        e.key[0] == CliExtensionsKey:
      continue
    let key = keyText(e.key)
    let id = byKey.getOrDefault(keyIndex(e.key), -1)
    if id < 0:
      raise newCliConfigError(cfeUnknownKey, layer.path, e.line, key,
        layer.name)
    let p = g.params[id]
    let list = p.isList and not p.counted
    let t = if p.counted: cctInteger else: p.configType
    var ok = false
    if list:
      ok = e.value.kind == ccvArray
      if ok:
        for item in e.value.items:
          if not fits(item, t):
            ok = false
    else:
      ok = fits(e.value, t)
    if not ok:
      raise newCliConfigError(cfeWrongType, layer.path, e.line, key,
        layer.name, expectedText(t, list), foundText(e.value))
    var c = CliCandidate(source: csFile, form: ccfValue, argvIndex: -1,
      valueArgvIndex: -1, group: index)
    let site = CliSite(kind: if layer.binding: cokEnforced else: cokFile,
      layer: layer.name, path: layer.path, line: e.line, key: key,
      fileSource: source, argvIndex: -1)
    if list:
      if e.value.items.len == 0:
        c.form = ccfEmpty
        sourced.addCandidate(id, c, site)
      for item in e.value.items:
        c.text = item.text
        c.verbatim = true
        sourced.addCandidate(id, c, site)
    else:
      c.text = e.value.text
      sourced.addCandidate(id, c, site)

proc cliEnvCandidates*(g: CliGrammar; env: Table[string, string];
                       sourced: var CliSourced) {.raises: [].} =
  ## Appends what the environment supplies to ``sourced``: for each
  ## parameter that the environment may supply, the first of its ``env``
  ## variables present in ``env``.
  for id, p in g.params:
    if csEnv notin p.sources:
      continue
    for name in p.env:
      if env.hasKey(name):
        sourced.addCandidate(id, CliCandidate(source: csEnv,
          form: ccfValue, text: env.getOrDefault(name), argvIndex: -1,
          valueArgvIndex: -1),
          CliSite(kind: cokEnv, variable: name, argvIndex: -1))
        break

proc cliSourceCandidates*(g: CliGrammar; sources: CliSources):
    CliSourced {.raises: [CliConfigError].} =
  ## Every candidate the layers and the environment supply, per parameter
  ## id, in the order the merge considers them: the layers lowest first,
  ## then the environment.
  result.candidates = newSeq[seq[CliCandidate]](g.params.len)
  for index, layer in sources.layers:
    cliLoadLayer(g, layer, index, sources.format, result)
  cliEnvCandidates(g, sources.env, result)

proc cliProcessEnv*(): Table[string, string] =
  ## The process's environment as a table, for a program that wants its
  ## parameters' ``env`` variables read from it.
  for name, value in envPairs():
    result[name] = value
