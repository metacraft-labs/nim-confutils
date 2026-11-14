## Origins: the record of how each configuration value was decided.
##
## A program described in clispec (https://github.com/metacraft-labs/nim-cli-spec)
## and instantiated through ``confutils/clispec_config`` takes each
## parameter's value from up to three kinds of source: configuration-file
## layers, environment variables and the command line. Every occurrence a
## source supplies is a clispec *candidate* (``CliCandidate``); the merge
## (``confutils/layers/merge``) picks the winners and records for every
## parameter a ``CliOrigin``: the winning source, and every other candidate
## that was considered, with the value it carried and what happened to it.
##
## A program reads the origins through the origin object generated beside
## the configuration object (``Tool.loadWithOrigins``): one ``CliOrigin``
## per field, in the same shape. That is what lets it explain an enforced
## setting, report its whole configuration and where each value came from,
## or pre-fill an editor with what a user would get.
##
## The command line's part of an origin, the argv index and the spelling
## used, is what clispec's parser records for each candidate it reads.

import std/strutils

import clispec/[model, candidates]

export candidates

type
  CliOriginKind* = enum
    ## Where a value came from.
    cokUnset = "unset"
      ## Nothing supplied it: the field holds its type's zero value.
    cokDefault = "default"
      ## The parameter's ``default``.
    cokFile = "file"
      ## A configuration file (path, line and the layer's name).
    cokEnv = "env"
      ## An environment variable.
    cokCli = "cli"
      ## The command line (argv index and the spelling used).
    cokImplied = "implied"
      ## Another parameter's ``implies``.
    cokEnforced = "enforced"
      ## A binding configuration layer, which no other source can override.

  CliSite* = object
    ## Where one value came from. Which fields are meaningful depends on
    ## ``kind``.
    kind*: CliOriginKind
    layer*: string
      ## The layer's name (``cokFile``, ``cokEnforced``).
    path*: string
      ## The configuration file (``cokFile``, ``cokEnforced``).
    line*: int
      ## Its line (``cokFile``, ``cokEnforced``).
    key*: string
      ## The configuration key, as the file spelt it (``cokFile``,
      ## ``cokEnforced``).
    fileSource*: string
      ## The file source whose spelling ``key`` is in: ``file``, or a named
      ## source the description declares with its own naming convention
      ## (``cokFile``, ``cokEnforced``).
    variable*: string
      ## The environment variable (``cokEnv``).
    argvIndex*: int
      ## The index in argv (``cokCli``); -1 otherwise.
    spelling*: string
      ## The spelling used on the command line (``cokCli``), in the command
      ## line's naming convention; empty for a positional.
    impliedBy*: string
      ## The name of the parameter whose ``implies`` set the value
      ## (``cokImplied``).

  CliFate* = enum
    ## What became of a candidate that is not the winner.
    cfOverridden = "overridden"
      ## A later (higher) source, or a later occurrence in the same source,
      ## replaced it.
    cfCombined = "combined"
      ## It is part of the value: ``merge = append`` or a combine proc took
      ## it together with the winner.
    cfIgnoredByEnforcement = "ignored by enforcement"
      ## A binding layer below it enforces the value, so it was ignored.

  CliLoser* = object
    ## A candidate that was considered and is not the winner.
    value*: string
      ## The value as written (``true`` / ``false`` for a bare or negated
      ## switch, ``1`` for one occurrence of a counted flag, the optional
      ## value's marker ``<bare>`` for a bare optional-value flag).
    site*: CliSite
    fate*: CliFate

  CliOrigin* = object
    ## How one parameter's value was decided.
    winner*: CliSite
      ## The winning source. For a value collected from several candidates
      ## (a list, a counted flag, ``append``, a combine proc) it is the last
      ## candidate considered.
    values*: seq[string]
      ## The winning value as written: the winning source's candidates (a
      ## list's elements), or the ``default`` / ``implies`` expression.
    losers*: seq[CliLoser]
      ## Every other candidate, in the order the merge considered them:
      ## configuration layers lowest first, then the environment, then the
      ## command line, each in its own order.

  CliSourcedValue*[T] = object
    ## One source's value, as a combine proc receives it.
    value*: T
    origin*: CliSite

func kind*(o: CliOrigin): CliOriginKind =
  ## The winning source's kind.
  o.winner.kind

func cliCommandLineSite*(c: CliCandidate): CliSite =
  ## The site of a candidate clispec's parser read from argv: its argv
  ## index and the spelling used.
  CliSite(kind: cokCli, argvIndex: c.argvIndex, spelling: c.spelling)

func cliSiteOf*(sites: openArray[CliSite]; c: CliCandidate): CliSite =
  ## Where a candidate came from: for the command line, what the parser
  ## recorded; for another source, its entry in ``sites`` (which the loader
  ## that made the candidate recorded at index ``c.site``).
  if c.source == csCli or c.site < 0 or c.site >= sites.len:
    cliCommandLineSite(c)
  else:
    sites[c.site]

func `$`*(s: CliSite): string =
  ## A human-readable description of a site: ``the command line ('--jobs',
  ## argument 2)``, ``environment variable TOOL_JOBS``,
  ## ``/etc/tool.toml:3 (layer 'system', binding)``, ``the default``.
  case s.kind
  of cokUnset: "nothing"
  of cokDefault: "the default"
  of cokImplied: "implied by '" & s.impliedBy & "'"
  of cokEnv: "environment variable " & s.variable
  of cokCli:
    if s.spelling.len > 0:
      "the command line ('" & s.spelling & "', argument " &
        $s.argvIndex & ")"
    else:
      "the command line (argument " & $s.argvIndex & ")"
  of cokFile, cokEnforced:
    s.path & ":" & $s.line & " (layer '" & s.layer & "'" &
      (if s.kind == cokEnforced: ", binding)" else: ")")

func cliDescribe*(o: CliOrigin): string =
  ## A one-line explanation of an origin: the winner and every loser with
  ## its fate (for a debug report or an ``--explain`` option).
  result = o.values.join(", ") & " from " & $o.winner
  for loser in o.losers:
    result.add("; " & loser.value & " from " & $loser.site & " " &
      $loser.fate)

template cliCombineFits*(T: typedesc; combine: untyped): bool =
  ## Whether ``combine`` can be a parameter of type ``T``'s combine proc:
  ## callable as ``combine(candidates)`` with an
  ## ``openArray[CliSourcedValue[T]]`` and returning a ``T``. Used by the
  ## checks ``cliConfiguration`` generates.
  compiles((block:
    let clispecCandidates: seq[CliSourcedValue[T]] = @[]
    let clispecProbe {.used.}: T = combine(clispecCandidates)
    clispecProbe))
