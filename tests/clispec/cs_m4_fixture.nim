## The program the ``test_cs_m4_*`` tests load, and their helpers.
##
## ``Cfg`` is a real clispec description, instantiated through confutils
## (``cliConfiguration``), using every source feature:
## environment variables, configuration keys (spelt ``snake_case`` through
## ``keyStyle``), each merge rule, a parameter the command line may not
## supply, defaults and an implication. The tests feed it real TOML files
## written to a fresh temporary directory and an environment passed in as a
## table; nothing is mocked, and the process's own environment is never
## read or changed.

import std/[os, tables, tempfiles]

import ../../confutils/clispec_config, ../../confutils/layers/toml_source

export clispec_config, toml_source, tables

type
  Color* = enum
    red, green, blue

var combineCalls*: seq[seq[CliSourcedValue[int]]]
  ## What ``strictest`` was given, call by call, so a test can check that
  ## the combine proc sees every candidate.

proc strictest*(candidates: openArray[CliSourcedValue[int]]): int =
  ## A combine proc: the highest level any source asks for. A negative
  ## level cannot be combined with anything, which tests a combine proc
  ## that rejects its input.
  combineCalls.add(@candidates)
  result = low(int)
  for c in candidates:
    if c.value < 0:
      raise newException(ValueError, "a negative level cannot be combined")
    result = max(result, c.value)

cliConfiguration(Cfg, "cfg", exported = true):
  configSchema "cfg.config.v1"
  keyStyle snakeCase
  help "A program with layered configuration"
  flag jobs is int, default = 4, env = ["CFG_JOBS"], help = "Parallel jobs"
  boolFlag verbose is bool, short = 'v', negatable = true,
    env = ["CFG_VERBOSE"]
  flag quiet is int, counted = true, short = 'q', env = ["CFG_QUIET"]
  flag color is Color, default = green, env = ["CFG_COLOR", "COLOR"]
  flag tags is seq[string], separator = ",", env = ["CFG_TAGS"]
  flag paths is seq[string], merge = append, separator = ":",
    env = ["CFG_PATHS"]
  flag level is int, merge = strictest, env = ["CFG_LEVEL"]
  flag mode is string, merge = errorOnConflict, env = ["CFG_MODE"]
  flag writeReport is string, env = ["CFG_REPORT"]
  flag token is string, sources = {env, file}, env = ["CFG_TOKEN"]
  flag note is string, sources = {cli}
  flag ratio is float
  call:
    boolFlag dry is bool
  subcmd "build":
    flag target is string, default = "all", env = ["CFG_TARGET"]
    flag optLevel is int, default = 2
    boolFlag release is bool, implies = [optLevel = 3]
    flag cacheDir is string, key = "build.cacheDir"

type
  Scratch* = object
    ## A fresh temporary directory for one test's files.
    dir*: string

proc newScratch*(): Scratch =
  Scratch(dir: createTempDir("clispec_cs_m4_", ""))

proc file*(s: Scratch; name, content: string): string =
  ## Writes ``content`` to ``name`` in the scratch directory and returns
  ## its path.
  result = s.dir / name
  writeFile(result, content)

proc remove*(s: Scratch) =
  removeDir(s.dir)

proc layer*(name, path: string; binding = false;
            required = false): CliLayer =
  CliLayer(name: name, path: path, binding: binding, required: required)

proc sources*(layers: openArray[CliLayer];
              env: openArray[(string, string)] = []): CliSources =
  ## The sources of one load: the layers, lowest first, read as TOML, and
  ## the environment ``env``.
  CliSources(layers: @layers, env: env.toTable, format: tomlCliFormat())

const header* = "schema = \"cfg.config.v1\"\n"
  ## The line every valid file starts with.
