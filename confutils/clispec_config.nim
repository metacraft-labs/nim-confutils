## Confutils over a clispec description.
##
## `Clispec <https://github.com/metacraft-labs/nim-cli-spec>`_ describes a
## command line once, declaratively, and generates from that description a
## typed configuration object, its argv parser, help and shell completion.
## This module instantiates confutils over such a description: clispec
## generates the configuration type and everything about the command line,
## and confutils adds what lies beyond the command line:
##
## * configuration-file layers, in the order and with the bindingness the
##   program declares (``confutils/layers/sources``), read through a format
##   adapter (TOML: ``confutils/layers/toml_source``) and validated against
##   a schema generated from the description;
## * the environment variables each parameter's ``env`` names;
## * each parameter's merge rule across those sources and the command line,
##   and the enforcement of binding layers (``confutils/layers/merge``);
## * an origin object of the configuration object's shape, recording where
##   every value came from and what it overrode
##   (``confutils/layers/origins``).
##
## The description is the single source of truth: ``env``, ``key``,
## ``sources``, ``merge``, ``configSchema`` and the per-source naming
## conventions are declared in it, and this module reads them from clispec's
## model. Parsing the command line, help and completion stay clispec's: they
## are delegated to the code clispec generates, so a program's help and
## completion are the same whether or not it reads configuration files.
##
## .. code-block:: nim
##   import confutils/clispec_config, confutils/layers/toml_source
##
##   cliConfiguration(Tool, "tool"):
##     configSchema "tool.config.v1"
##     convention file = snakeCase
##     flag jobs is int, default = 4, env = ["TOOL_JOBS"]
##
##   let sources = CliSources(format: tomlCliFormat(),
##     layers: @[CliLayer(name: "user", path: "tool.toml")],
##     env: cliProcessEnv())
##   let (conf, origins) = Tool.loadWithOrigins(@["--jobs", "8"], sources)
##
## ``cliConfiguration`` takes exactly what clispec's ``cliProgram`` takes and
## generates everything ``cliProgram`` does (``Tool``, ``Tool.load(argv)``,
## ``Tool.helpText``, ``Tool.complete``, ...), and also:
##
## * ``Tool.load(argv, sources, options)`` and ``Tool.load(sources,
##   options)`` (the process's own arguments), which read the layers and
##   the environment of a ``CliSources`` too, and raise ``CliConfigError``
##   for a configuration file that does not fit the program's schema;
## * ``Tool.loadWithOrigins(argv, sources, options)``, returning
##   ``tuple[config: Tool, origins: ToolOrigins]``: the origin object has
##   the configuration object's shape (``ToolOrigins``, ``ToolBuildOrigins``,
##   the same ``command`` discriminator) with a ``CliOrigin`` per field;
## * ``Tool.configSchema`` and ``Tool.configSchema(source)``, the schema of
##   the program's configuration files, with its keys spelt as the ``file``
##   source or the named file source ``source`` spells them;
## * a compile-time check of every combine proc (``merge = <proc>``): it
##   must be callable as ``proc (candidates:
##   openArray[CliSourcedValue[T]]): T`` for the parameter's type ``T``.
##
## A consumer whose clispec model carries an extension generates the same
## code from its own macro: ``cliProgramCode`` followed by
## ``cliConfigurationCode``.

import std/[macros, strutils]

import clispec

import ./layers/[origins, sources, merge]

export clispec, origins, sources, merge

proc combineChecks[P](decls: seq[CliParam[P]]): NimNode =
  ## A compile error naming the parameter for a combine proc that cannot be
  ## called as the merge calls it.
  result = newStmtList()
  for p in decls:
    if p.merge != cmrCombine:
      continue
    let c = p.combine
    result.add(cliFailWhenNot(newCall(bindSym("cliCombineFits"),
      parseExpr(p.nimType), parseExpr(c.code)), "clispec: parameter '" &
      p.name & "': merge = `" & c.code & "` is not a combine proc for " &
      p.nimType & "; it must be callable as proc (candidates: " &
      "openArray[CliSourcedValue[" & p.nimType & "]]): " & p.nimType,
      c.sourceFile, c.sourceLine, c.sourceColumn))

proc problemAt(message, file: string; line: int) =
  let n = newEmptyNode()
  n.setLineInfo(file, line, 0)
  error(message, n)

proc combineStmt[P](g: CliGrammar; id: int; decl: CliParam[P]): NimNode =
  ## Sets ``target.<field>`` from the parameter's combine proc, when the
  ## merge says it combines.
  let fieldType = parseExpr(g.params[id].nimType)
  let bare = cliFieldBare(decl, fieldType)
  let (allowedDecl, allowed) = cliFieldAllowed(decl, fieldType)
  let inputs = genSym(nskLet, "inputs")
  let err = genSym(nskLet, "e")
  let target = newDotExpr(ident("target"),
    nnkAccQuoted.newTree(ident(g.params[id].name)))
  let gram = ident("g")
  let lr = ident("lr")
  newIfStmt((newCall(bindSym("cliCombines"), gram, lr, newLit(id)),
    newStmtList(
      allowedDecl,
      newLetStmt(inputs, newCall(bindSym("cliCombineInputs"), gram, lr,
        newLit(id), bare, allowed)),
      nnkTryStmt.newTree(
        newStmtList(newAssignment(target,
          newCall(parseExpr(decl.combine.code), inputs))),
        nnkExceptBranch.newTree(
          infix(ident("CatchableError"), "as", err),
          newStmtList(newCall(bindSym("cliCombineFailed"), gram, lr,
            newLit(id), newDotExpr(err, ident("msg")))))))))

proc cliConfigurationCode*[C, P](model: CliModel[C, P]; typeName,
                                 program: string; exported: bool): NimNode =
  ## The code ``cliConfiguration`` adds to clispec's ``cliProgramCode`` for
  ## the same model and type name: the origin object types, the loaders
  ## over configuration layers and the environment, the configuration
  ## schema and the combine procs' checks. Place it after
  ## ``cliProgramCode``'s output, at the description's scope, which must
  ## import ``confutils/clispec_config``.
  var problems: seq[CliGrammarProblem] = @[]
  var decls: seq[CliParam[P]] = @[]
  let g = cliGrammarOf(model, program, problems, decls)
  # cliProgramCode reports ``problems``; a description with any never gets
  # this far.
  let names = cliGeneratedNames(g, typeName)
  const suffix = "Origins"
  # A command's origin object type must not be another command's type
  # (``subcmd "origins"`` of ``Tool`` would be ``ToolOrigins``).
  for k in 0 ..< g.commands.len:
    for kk in 0 ..< g.commands.len:
      if cliHasObject(g, k) and cliHasObject(g, kk) and
          names.typeNames[k] & suffix == names.typeNames[kk]:
        problemAt("clispec: the origin object of " &
          (if k == 0: "the root command"
           else: "command '" & g.commands[k].path.join(" ") & "'") &
          " would be the type " & names.typeNames[k] & suffix &
          ", which is already the configuration object of command '" &
          g.commands[kk].path.join(" ") & "'", g.commands[kk].sourceFile,
          g.commands[kk].sourceLine)
  result = newStmtList(combineChecks(decls))
  var typeSection = nnkTypeSection.newTree()
  for k in 0 ..< g.commands.len:
    if cliHasObject(g, k):
      for decl in cliShapedTypeDecls(g, names, k, suffix,
          bindSym("CliOrigin"), exported):
        typeSection.add(decl)
  result.add(typeSection)
  # The origin builders and the combine visitors, innermost first so each
  # one's callees are declared.
  var originValues: seq[NimNode] = @[]
  var combineStmts: seq[NimNode] = @[]
  for id in 0 ..< g.params.len:
    originValues.add(nnkBracketExpr.newTree(ident("o"), newLit(id)))
    combineStmts.add(if decls[id].merge == cmrCombine:
                       combineStmt(g, id, decls[id])
                     else: newEmptyNode())
  let originsParam = newIdentDefs(ident("o"),
    nnkBracketExpr.newTree(ident("seq"), bindSym("CliOrigin")))
  let lrParam = newIdentDefs(ident("lr"), bindSym("CliLayeredResolution"))
  for k in countdown(g.commands.high, 0):
    if cliHasObject(g, k):
      let builder = cliShapedBuilderProc(g, names, k, suffix,
        "cliOriginsOf", @[originsParam.copyNimTree], originValues)
      builder.addPragma(nnkExprColonExpr.newTree(ident("raises"),
        nnkBracket.newTree()))
      result.add(builder)
      result.add(cliShapedVisitorProc(g, names, k, "cliCombine",
        @[lrParam.copyNimTree], combineStmts, @[ident("CliUsageError")]))

  let T = ident(typeName)
  let O = ident(typeName & suffix)
  let rootBuilder = cliBuilderName(names, 0)
  let rootOrigins = ident("cliOriginsOf" & typeName)
  let rootCombine = ident("cliCombine" & typeName)
  let completers = cliCompletersName(names)
  let valueCheck = cliValueCheckName(names)
  proc exportedName(name: string): NimNode =
    if exported: postfix(nnkAccQuoted.newTree(ident(name)), "*")
    else: nnkAccQuoted.newTree(ident(name))
  let loadName = exportedName("load")
  let loadWithOriginsName = exportedName("loadWithOrigins")
  let configSchemaName = exportedName("configSchema")
  let resolveName = genSym(nskProc, "resolve")
  result.add quote do:
    proc `resolveName`(g: CliGrammar; argv: openArray[string];
                       sources: CliSources; options: CliOptions):
        CliLayeredResolution {.
        raises: [CliUsageError, CliHelpRequest, CliConfigError].} =
      # The command line's completion protocol first, as clispec's own
      # ``load`` does, then every source. The parser gets the description's
      # value check, as clispec's ``load`` gives it, for the rules that
      # need one (``acceptsNextWord``, ``valueErrorsBeforeHelp``).
      let opts = cliWithValueCheck(options, `valueCheck`)
      if cliIsCompletionRequest(argv, opts):
        cliCompletionCheck(g, `completers`(), argv, opts)
      cliResolve(g, argv, sources, opts)

    proc `loadName`(t: typedesc[`T`]; argv: openArray[string];
                    sources: CliSources; options = CliOptions()): `T` {.
        raises: [CliUsageError, CliHelpRequest, CliConfigError].} =
      ## Fills a configuration object from the configuration layers and the
      ## environment of ``sources`` and from ``argv``, merged as each
      ## parameter declares. Raises ``CliConfigError`` for a configuration
      ## file that does not fit the program's schema, and what clispec's
      ## ``load`` raises for the command line.
      let g = `T`.cliGrammar()
      var lr = `resolveName`(g, argv, sources, options)
      result = `rootBuilder`(g, lr.resolution)
      `rootCombine`(g, lr.resolution, lr, result)

    proc `loadName`(t: typedesc[`T`]; sources: CliSources;
                    options = CliOptions()): `T` {.
        raises: [CliUsageError, CliHelpRequest, CliConfigError].} =
      ## ``load`` over ``sources`` and the process's own arguments.
      `loadName`(t, cliCommandLineParams(), sources, options)

    proc `loadWithOriginsName`(t: typedesc[`T`]; argv: openArray[string];
                               sources = CliSources();
                               options = CliOptions()):
        tuple[config: `T`, origins: `O`] {.
        raises: [CliUsageError, CliHelpRequest, CliConfigError].} =
      ## ``load``, and the origin object: for every field, where its value
      ## came from and every other value that was considered.
      let g = `T`.cliGrammar()
      var lr = `resolveName`(g, argv, sources, options)
      var conf = `rootBuilder`(g, lr.resolution)
      `rootCombine`(g, lr.resolution, lr, conf)
      (conf, `rootOrigins`(g, lr.resolution, lr.origins))

    proc `configSchemaName`(t: typedesc[`T`]): CliConfigSchema =
      ## The schema of the program's configuration files: the identifier
      ## they declare and every valid key with its type, spelt as the
      ## ``file`` source spells it.
      cliConfigSchemaOf(`T`.cliGrammar())

    proc `configSchemaName`(t: typedesc[`T`]; source: string):
        CliConfigSchema =
      ## The schema with its keys spelt as the file source ``source`` (a
      ## named source the description declares) spells them.
      cliConfigSchemaOf(`T`.cliGrammar(), source)

macro cliConfiguration*(args: varargs[untyped]): untyped =
  ## Generates, from a clispec ``cli:`` description, what clispec's
  ## ``cliProgram`` generates (the configuration object, its command-line
  ## parser, help and completion) and confutils' layered loading over it
  ## (see the module documentation):
  ##
  ## .. code-block:: nim
  ##   cliConfiguration(Tool, "tool", exported = true):
  ##     configSchema "tool.config.v1"
  ##     flag jobs is int, default = 4, env = ["TOOL_JOBS"]
  let a = cliProgramArgs(args, "cliConfiguration")
  let model = parseCliModel[NoCliExtension, NoCliExtension](a.body,
    NoCliExtension())
  result = cliProgramCode(model, a.typeName, a.program, a.exported)
  result.add(cliConfigurationCode(model, a.typeName, a.program, a.exported))
