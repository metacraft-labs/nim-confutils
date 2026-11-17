## Merging configuration layers, the environment and the command line.
##
## Clispec parses a program's command line in phases (``clispec/parser``):
## ``cliTokenize`` reads argv into candidates, a merge decides which
## candidates make up each parameter's value, ``cliDecide`` applies
## implications and defaults, and the generated code builds the typed
## configuration object. This module is the merge phase for a program that
## also reads configuration-file layers and the environment
## (``confutils/layers/sources``): ``cliMerge`` takes the command line's
## candidates and the other sources', applies each parameter's merge rule
## and the binding layers' enforcement, and records every parameter's
## origin (``confutils/layers/origins``). The result is clispec's own
## ``CliResolution``, so clispec decides defaults and builds the object
## exactly as it does for the command line alone.
##
## Each source (one layer, the environment, the command line) gives one
## value first: within it a list collects every occurrence, a counted flag
## adds up its occurrences, anything else keeps its last. Across sources:
##
## * a source that is a binding layer wins outright (the lowest one, when
##   several bind the parameter): its value is enforced, the sources below
##   it are overridden and the ones above it ignored;
## * ``replace`` (the default): the highest source wins, the others are
##   overridden;
## * ``errorOnConflict``: as ``replace``, but two sources with different
##   values raise ``cekConflictingSources`` naming both;
## * ``append`` and a combine proc: every source is part of the value,
##   lowest first, and the others are recorded as combined.
##
## Defaults and ``implies`` apply only after the merge, so a default never
## stands in for a value a source supplied.

import std/strutils

import clispec/[model, grammar, errors, parser, candidates]

import ./[origins, sources]

export origins, sources

type
  CliLayeredResolution* = object
    ## Everything decided before the typed configuration object and its
    ## origin object are built.
    resolution*: CliResolution
      ## Clispec's resolution: the selected commands, each parameter's
      ## merged candidates and its decision.
    sites*: seq[CliSite]
      ## Where the candidates of the layers and the environment came from
      ## (a candidate's ``site`` indexes it).
    origins*: seq[CliOrigin]
      ## Per parameter id: how the value was decided.

func normalBool(text: string): string =
  case text.toLowerAscii()
  of "true", "yes", "on", "1": "true"
  of "false", "no", "off", "0": "false"
  else: text

func groupValue(p: CliGrammarParam; cands: openArray[CliCandidate]):
    seq[string] =
  ## What one source's candidates say, as text, for comparing two sources
  ## (``errorOnConflict``): a counted flag's count, a list's elements, else
  ## the last candidate's value, a switch's spelled ``true`` / ``false``.
  if p.counted:
    var n = 0
    var exact = true
    for c in cands:
      case c.form
      of ccfCount: inc n
      of ccfValue:
        try: n += parseInt(c.text)
        except ValueError: exact = false
      else: discard
    return (if exact: @[$n] else: @[cands[^1].text])
  if p.isList:
    for c in cands:
      case c.form
      of ccfValue:
        if p.separator.len > 0 and not c.verbatim:
          for piece in c.text.split(p.separator):
            result.add(piece)
        else:
          result.add(c.text)
      of ccfBare: result.add("<bare>")
      else: discard
    return
  let c = cands[^1]
  case c.form
  of ccfValue: @[if p.isSwitch: normalBool(c.text) else: c.text]
  of ccfBare: @[if p.isSwitch and not p.hasOptionalValue: "true" else: "<bare>"]
  of ccfNegated: @["false"]
  of ccfCount: @["1"]
  of ccfEmpty: @[]

func shown(values: seq[string]): string =
  "'" & values.join(", ") & "'"

proc cliMerge*(g: CliGrammar; tokens: CliTokens; sourced: CliSourced;
               options = CliOptions()): CliLayeredResolution {.
    raises: [CliUsageError].} =
  ## The merge phase over every source: for each parameter of the selected
  ## commands, the candidates its value is made of, and its origin.
  ## ``sourced`` holds what the configuration layers and the environment
  ## supply (``cliSourceCandidates``), lowest first; the command line's
  ## candidates (``tokens``, from clispec's ``cliTokenize``) come after
  ## them. The rules are in the module documentation.
  ##
  ## The origin's ``losers`` list every candidate outside the winning
  ## source (and the earlier occurrences of a scalar within it), in the
  ## order they were considered.
  var r = cliNewResolution(g, tokens, options)
  result.sites = sourced.sites
  result.origins = newSeq[CliOrigin](g.params.len)
  for id in cliVisibleParams(g, tokens.selected):
    var all: seq[CliCandidate] = @[]
    if id < sourced.candidates.len:
      all.add(sourced.candidates[id])
    all.add(tokens.candidates[id])
    if all.len == 0:
      continue
    let p = g.params[id]
    let groups = cliCandidateGroups(all)
    var binding = -1
    for k, grp in groups:
      if grp[0].source == csFile and
          cliSiteOf(sourced.sites, grp[0]).kind == cokEnforced:
        binding = k
        break
    let collects = binding < 0 and p.merge in {cmrAppend, cmrCombine}
    let winner = if binding >= 0: binding else: groups.high
    if binding < 0 and p.merge == cmrErrorOnConflict:
      let first = groupValue(p, groups[0])
      for k in 1 .. groups.high:
        let other = groupValue(p, groups[k])
        if other != first:
          let a = groups[0][^1]
          let b = groups[k][^1]
          let at = if b.source == csCli: b.argvIndex
                   elif a.source == csCli: a.argvIndex
                   else: -1
          raise newCliUsageError(cekConflictingSources, r.program,
            g.commands[p.declaredBy].path, at, cliDisplayName(p),
            detail = shown(first) & " from " & $cliSiteOf(sourced.sites, a) &
              " and " & shown(other) & " from " &
              $cliSiteOf(sourced.sites, b),
            exitCode = r.exitCode)
    var origin = CliOrigin()
    for k, grp in groups:
      let eff = cliEffective(p, grp)
      for j, c in grp:
        let inValue = eff[j] and (k == winner or collects)
        if inValue:
          r.merged[id].add(c)
          origin.values.add(cliCandidateValueText(c))
          if c.source == csCli:
            origin.commandLine.add(c)
        else:
          r.overridden[id].add(c)
        if k == winner and eff[j]:
          continue
        let fate = if binding >= 0 and k > binding: cfIgnoredByEnforcement
                   elif inValue: cfCombined
                   else: cfOverridden
        var site = cliSiteOf(sourced.sites, c)
        if site.kind == cokEnforced:
          # Only the winning binding layer enforces; a higher one that
          # also binds the parameter lost like any other file.
          site.kind = cokFile
        origin.losers.add(CliLoser(value: cliCandidateValueText(c),
          site: site, fate: fate))
    origin.winner = cliSiteOf(sourced.sites, groups[winner][^1])
    result.origins[id] = origin
  result.resolution = r

proc cliDecide*(g: CliGrammar; lr: var CliLayeredResolution) {.
    raises: [CliUsageError].} =
  ## Clispec's decision phase (implications, defaults, required parameters)
  ## over a merged resolution, recording an implied or default value's
  ## origin.
  cliDecide(g, lr.resolution)
  for id in cliVisibleParams(g, lr.resolution.selected):
    let d = lr.resolution.decisions[id]
    case d.kind
    of cdkImplied:
      let src = g.params[d.impliedBy]
      lr.origins[id] = CliOrigin(winner: CliSite(kind: cokImplied,
        argvIndex: -1, impliedBy: src.name),
        values: @[src.impliesText[d.implication]])
    of cdkDefault:
      lr.origins[id] = CliOrigin(winner: CliSite(kind: cokDefault,
        argvIndex: -1), values: @[g.params[id].defaultText])
    of cdkSource, cdkUnset:
      discard

proc cliResolve*(g: CliGrammar; argv: openArray[string];
                 sources: CliSources; options = CliOptions()):
    CliLayeredResolution {.raises: [CliUsageError, CliHelpRequest,
                                    CliConfigError].} =
  ## Every phase before the typed objects are built, over every source: the
  ## configuration layers and the environment of ``sources``, then the
  ## command line. The command line is read first, so a request for help or
  ## a usage error is reported even when a configuration file is broken.
  let tokens = cliTokenize(g, argv, options)
  let sourced = cliSourceCandidates(g, sources)
  result = cliMerge(g, tokens, sourced, options)
  cliDecide(g, result)

func cliCombines*(g: CliGrammar; lr: CliLayeredResolution; id: int): bool =
  ## Whether parameter ``id``'s value goes through its combine proc: its
  ## merge rule is a combine proc, a source supplied it and no binding
  ## layer enforces it.
  g.params[id].merge == cmrCombine and
    lr.resolution.decisions[id].kind == cdkSource and
    lr.origins[id].kind != cokEnforced

proc cliCombineInputs*[T, E](g: CliGrammar; lr: CliLayeredResolution;
                             id: int; bare: proc (): T {.raises: [].};
                             allowed: openArray[E]):
    seq[CliSourcedValue[T]] {.raises: [CliUsageError].} =
  ## What a combine proc receives for parameter ``id``: one value per source
  ## that supplied it, lowest first, each converted from that source's
  ## candidates (clispec's ``cliConvertCandidates``), with the source's
  ## site.
  for grp in cliCandidateGroups(lr.resolution.merged[id]):
    var v: T
    cliConvertCandidates(g, lr.resolution, id, grp, v, bare, allowed)
    result.add(CliSourcedValue[T](value: v,
      origin: cliSiteOf(lr.sites, grp[^1])))

proc cliCombineFailed*(g: CliGrammar; lr: CliLayeredResolution; id: int;
                       message: string) {.noreturn,
                       raises: [CliUsageError].} =
  ## A combine proc raised: the values its sources gave cannot be combined.
  let p = g.params[id]
  raise newCliUsageError(cekConflictingSources, lr.resolution.program,
    g.commands[p.declaredBy].path, -1, cliDisplayName(p), detail = message,
    exitCode = lr.resolution.exitCode)
