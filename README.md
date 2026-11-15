nim-confutils
=============

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Github action](https://github.com/status-im/nim-confutils/workflows/CI/badge.svg)

## Introduction

Confutils is a library that aims to solve the configuration problem
with a holistic approach. The run-time configuration of a program
is described as a plain Nim object type from which the library
automatically derives the code for handling command-line options,
configuration files and other platform-specific sources such as the
Windows registry.

The library focuses on providing a lot of compile-time configurability
and extensibility with a strong adherence to the DRY principle.

Let's illustrate the API with a highly annotated example. Our configuration
might be described in a separate module looking like this:

```nim
# config.nim
import
  confutils/defs

type
  NimbusConf* = object
    #
    # This is our configuration type.
    #
    # Each field will be considered a configuration option that may appear
    # on the command-line, whitin an environment variable or a configuration
    # file, or elsewhere. Custom pragmas are used to annotate the fields with
    # additional metadata that is used to augment the behavior of the library.
    #
    logLevel* {.
      defaultValue: LogLevel.INFO
      desc: "Sets the log level" }: LogLevel

    #
    # This program uses a CLI interface with sub-commands (similar to git).
    #
    # The `StartUpCommand` enum provides the list of available sub-commands,
    # but since we are specifying a default value of `noCommand`, the user
    # can also launch the program without entering any particular command.
    # The default command will also be omitted from help messages.
    #
    # Please note that the `logLevel` option above will be shared by all
    # sub-commands. The rest of the nested options will be relevant only
    # when the designated sub-command is being invoked.
    #
    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      dataDir* {.
        defaultValue: getConfigDir() / "nimbus"
        desc: "The directory where nimbus will store all blockchain data."
        abbr: "d" }: DirPath

      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        abbr: "b"
        name: "bootstrap-node" }: seq[string]

      bootstrapNodesFile* {.
        defaultValue: ""
        desc: "Specifies a line-delimited file of bootsrap Ethereum network addresses"
        abbr: "f" }: InputFile

      tcpPort* {.
        desc: "TCP listening port" }: int

      udpPort* {.
        desc: "UDP listening port" }: int

      validators* {.
        required
        desc: "A path to a pair of public and private keys for a validator. " &
              "Nimbus will automatically add the extensions .privkey and .pubkey."
        abbr: "v"
        name: "validator" }: seq[PrivateValidatorData]

      stateSnapshot* {.
        desc: "Json file specifying a recent state snapshot"
        abbr: "s" }: Option[BeaconState]

    of createChain:
      chainStartupData* {.
        desc: ""
        abbr: "c" }: ChainStartupData

      outputStateFile* {.
        desc: "Output file where to write the initial state snapshot"
        name: "out"
        abbr: "o" }: OutFilePath

  StartUpCommand* = enum
    noCommand
    createChain

  #
  # The configuration can use user-defined types that feature custom
  # command-line parsing and serialization routines.
  #
  PrivateValidatorData* = object
    privKey*: ValidatorPrivKey
    randao*: Randao

```

Then from our main module, we just need to call `confutils.load` which must be
given our configuration type as a parameter:

```nim
# main.nim
import
  confutils, config

when isMainModule:
  let conf = NimbusConf.load()
  initDatabase conf.dataDir
```

And that's it - calling `load` with default parameters will first process any
[command-line options](#handling-of-command-line-options) and then it will
try to load any missing options from the most appropriate
[configuration location](#handling-of-environment-variables-and-config-files)
for the platform. Diagnostic messages will be provided for many simple
configuration errors and the following help message will be produced
automatically when calling the program with `program --help`:

```
Usage: beacon_node [OPTIONS] <command>

The following options are supported:

  --logLevel=LogLevel                        : Sets the log level
  --dataDir=DirPath                          : The directory where nimbus will store all blockchain data.
  --bootstrapNode=seq[string]                : Specifies one or more bootstrap nodes to use when connecting to the network.
  --bootstrapNodesFile=FilePath              : Specifies a line-delimited file of bootsrap Ethereum network addresses
  --tcpPort=int                              : TCP listening port
  --udpPort=int                              : UDP listening port
  --validator=seq[PrivateValidatorData]      : A path to a pair of public and private keys for a validator. Nimbus will automatically add the extensions .privkey and .pubkey.
  --stateSnapshot=Option[BeaconState]        : Json file specifying a recent state snapshot

Available sub-commands:

  beacon_node createChain

  --out=OutFilePath                          : Output file where to write the initial state snapshot

```

For simpler CLI utilities, Confutils also provides the following convenience APIs:

```nim
import
  confutils

cli do (validators {.
          desc: "number of validators"
          abbr: "v" }: int,

        outputDir {.
          desc: "output dir to store the generated files"
          abbr: "o" }: OutPath,

        startupDelay {.
          desc: "delay in seconds before starting the simulation" } = 0):

  if validators < 64:
    echo "The number of validators must be greater than EPOCH_LENGTH (64)"
    quit(1)
```

```nim
import
  confutils

proc main(foo: string, bar: int) =
  ...

dispatch(main)
```

Under the hood, using these APIs will result in calling `load` on an anonymous
configuration type having the same fields as the supplied proc params.
Any additional arguments given as `cli(args) do ...` and `dispatch(fn, args)`
will be passed to `load` without modification. Please note that this requires
all parameters types to be concrete (non-generic).

This covers the basic usage of the library and the rest of the documentation
will describe the various ways the default behavior can be tweaked or extended.


## Configuration field pragmas

A number of pragmas defined in `confutils/defs` can be attached to the
configuration fields to control the behavior of the library.

```nim
template desc*(v: string) {.pragma.}
```

A description of the configuration option that will appear in the produced
help messages.

```nim
template longDesc*(v: string) {.pragma.}
```

A long description text that will appear below regular desc. You can use
one of {'\n', '\r'} to break it into multiple lines. But you can't use
'\p' as line break.

```text
 -x, --name   regular description [=defVal].
              longdesc line one.
              longdesc line two.
              longdesc line three.
```
-----------------

```nim
template name*(v: string) {.pragma.}
```

A long name of the option.
Typically, it will have to be be specified as `--longOptionName value`.
See [Handling of command-line options](#handling-of-command-line-options)
for more details.

-----------------

```nim
template abbr*(v: string) {.pragma.}

```

A short name of the option.
Typically, it will be required to be specified as `-x value`.
See [Handling of command-line options](#handling-of-command-line-options)
for more details.

-----------------

```nim
template defaultValue*(v: untyped) {.pragma.}
```

The default value of the option if no value was supplied by the user.

-----------------

```nim
template required* {.pragma.}
```

By default, all options without default values are considered required.
An exception to this rule are all `seq[T]` or `Option[T]` options for
which the "empty" value can be considered a reasonable default. You can
also extend this behavior to other user-defined types by providing the
following overloads:

```nim
template hasDefault*(T: type Foo): bool = true
template default*(T: type Foo): Foo = Foo(...)
```

The `required` pragma can be applied to fields having such defaultable
types to make them required.

-----------------

```nim
template command* {.pragma.}
```

This must be applied to an enum field that represents a possible sub-command.
See the section on [sub-commands](#Using-sub-commands) for more details.

-----------------

```nim
template argument* {.pragma.}
```

This field represents an argument to the program. If the program expects
multiple arguments, this pragma can be applied to multiple fields or to
a single `seq[T]` field depending on the desired behavior.

-----------------

```nim
template separator(v: string)* {.pragma.}
```

Using this pragma, a customizable separator text will be displayed just before
this field. E.g.:

```text
Network Options:     # this is a separator
  -a, --opt1 desc
  -b, --opt2 desc

----------------     # this is a separator too
  -c, --opt3 desc
```

## Configuration field types

The `confutils/defs` module provides a number of types frequently used
for configuration purposes:

#### `InputFile`, `InputDir`

Confutils will validate that the file/directory exists and that it can
be read by the current user.

#### `ConfigFilePath[Format]`

A file system path pointing to a configuration file in the specific format.
The actual configuration can be loaded by calling `load(path, ConfigType)`.
When the format is `WindowsRegistry` the path should indicate a registry key.

#### `OutPath`

A valid path must be given.

--------------

Furthermore, you can extend the behavior of the library by providing
overloads such as:

```nim
proc parseCmdArg*(T: type Foo, p: string): T =
  ## This provides parsing and validation for fields having the `Foo` type.
  ## You should raise `ConfigurationError` in case of detected problems.
  ...

proc humaneTypeName*[T](_: type MyList[T]): string =
  ## The returned string will be used in the help messages produced by the
  ## library to describe the expected type of the configuration option.
  mixin humaneTypeName
  return "list of " & humaneTypeName(T)
```

For config files, Confutils can work with any format supported by the
[nim-serialization](https://github.com/status-im/nim-serialization/) library
and it will use the standard serialization routines defined for the field
types in this format. Fields marked with the `command` or `argument` pragmas
will be ignored.

## Handling of command-line options

Confutils includes parsers that can mimic several traditional styles of
command line interfaces. You can select the parser being used by specifying
the `CmdParser` option when calling the configuration loading APIs.

The default parser of Confutils is called `MixedCmdParser`. It tries to follow
the [robustness principle](https://en.wikipedia.org/wiki/Robustness_principle)
by recognizing as many styles of passing command-line switches as possible.
A prefix of `--` is used to indicate a long option name, while the `-` prefix
uses the short option name. Multiple short options such as `-a`, `-b` and
`-c` can be combined into a single `-abc` string. Both the long and the short
forms can also be prefixed with `/` in the style of Windows utilities. The
long option names are matched in case-insensitive fashion and certain characters
such as `_` will be ignored. A single-character (short) name is matched
case-sensitively, so `-f` and `-F` can be two different options. The values
can be separated from the option names with a space, colon or an equal sign.
`bool` and `Option[bool]` flags are switches: merely including them in the
command line sets them to `true`, they never take their value from the next
argument, and `--flag=false` sets one explicitly. A `bool` flag defaults to
`false`; an `Option[bool]` one stays `none` when it is not given.

Other provided choices are `UnixCmdParser`, `WindowsCmdParser` and `NimCmdParser`
which are based on more strict grammars following the most established
tradition of the respective platforms. All of the discussed parsers are
defined in terms of the lower-level parametric type `CustomCmdParser` that
can be tweaked further for a more custom behavior.

Please note that the choice of `CmdParser` will also affect the formatting
of the help messages. Please see the definition of the standard [Windows][WIN_CMD]
or [Posix][POSIX_CMD] command-line help syntax for mode details.

[WIN_CMD]: https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/command-line-syntax-key
[POSIX_CMD]: http://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html

### Using sub-commands

As seen in the [introduction example](#introduction), Confutils makes it
easy to create command-line interfaces featuring sub-commands in the style
of `git` or `nimble`. The structure of the sub-command tree is encoded as
a Nim case object where the sub-command name is represented by an `enum`
field having the `command` pragma. Any nested fields will be considered
options of the particular sub-command. The top-level fields will be shared
between all sub-commands.

For each available choice of command and options, Confutils will automatically
provide a `help` command and the following additional switches:

* `-h` will print a short syntax reminder for the command
* `--help` will print a full help message (just like the `help` command)

## Handling of environment variables and config files

After parsing the command line options, the default behavior of Confutils is
to try to fill any missing options by examining the contents of the environment
variables plus two per-user and system-wide configuration locations derived from
the program name. If you want to use Confutils only as a command-line processor
or a config file parser for example, you can supply an empty/nil value to the
`cmdLine`, `envTable` or `configFileEnumerator` parameters of the `load` call.

More specifically, the `load` call supports the following parameters:

#### `cmdLine`, `envTable`

The command-line parameters and the environment table of the program.
By default, these will be obtained through Nim's `os` module.

#### `EnvValuesFormat`, `envVarsPrefix`

A nim-serialization format used to deserialize the values of environment
variables. The default format is called `CmdLineFormat` and it uses the
same `parseCmdArg` calls responsible for parsing the command-line.

The names of the environment variables are prefixed by the name of the
program by default and joined with the name of command line option, which is 
uppercased and characters `-` and spaces are replaced with underscore:

```nim
let env_variable_name = &"{prefix}_{key}".toUpperAscii.multiReplace(("-", "_"), (" ", "_"))
```

#### `configFileEnumerator`

A function responsible for returning a sequence of `ConfigFilePath` objects.
To support heterogenous config file types, you can also return a tuple of
sequences. The default behavior of Windows is to obtain the configuration
from the Windows registry by looking at the following keys:

```
HKEY_CURRENT_USER/SOFTWARE/{appVendor}/{appName}/
HKEY_LOCAL_MACHINE/SOFTWARE/{appVendor}/{appName}/
```

On Posix systems, the default behavior is attempt to load the configuration
from the following files:

```
/$HOME/.config/{appName}.{ConfigFileFormat.extension}
/etc/{appName}.{ConfigFileForamt.extension}
```

#### `ConfigFileFormat`

A [nim-serialization](https://github.com/status-im/nim-serialization) format
that will be used by default by Confutils.

## Customization of the help messages

The `load` call offers few more optional parameters for modifying the
produced help messages:

#### `bannerBeforeHelp`

A copyright banner or a similar message that will appear before the
automatically generated help messages.

#### `bannerAfterHelp`

A copyright banner or a similar message that will appear after the
automatically generated help messages.

#### `version`

If you provide this parameter, Confutils will automatically respond
to the standard `--version` switch. If sub-commands are used, an
additional `version` top-level command will be inserted as well.

## Compile-time options

#### `confutils_no_colors`

Defining it (`-d:confutils_no_colors`) turns off the colours and styles
in the help and error messages produced by Confutils. By default they
are on: ANSI escape codes on Unix-like systems, console attributes on
Windows (through Nim's `terminal` module). The attribute resets that
`styledWrite` adds are still written. Under NimScript the output is
always colourless.

## Compile-time options of your own library

A library configured with `-d:name=value` switches can declare each option
as a typed constant with the attribute macros of `confutils/defines`, instead
of reading a `{.strdefine.}` string and converting it by hand. The module
needs only Nim's standard library (Nim 2.0 or later).

```nim
# mylib.nim
import confutils/defines

type
  LogLevel* = enum
    TRACE, DEBUG, INFO, WARN

  Colors* = enum
    NoColors, AnsiColors, NativeColors

const
  mylib_log_level* {.enumDefine.}: LogLevel = INFO
  mylib_stack_traces* {.flagDefine.} = false
  mylibColors* {.enumDefine("mylib.colors", offValue = NoColors).} =
    NativeColors

when isMainModule:
  echo mylib_log_level, " ", mylib_stack_traces, " ", mylibColors
```

```text
$ nim c -r mylib.nim
INFO false NativeColors
$ nim c -r -d:mylib_log_level=debug -d:mylib_stack_traces=on -d:mylib.colors=off mylib.nim
DEBUG true NoColors
$ nim c -r -d:mylib_log_level=verbose mylib.nim
mylib.nim(12, 3) Error: invalid value 'verbose' for the compile-time option 'mylib_log_level' (-d:mylib_log_level=verbose); allowed values: TRACE, DEBUG, INFO, WARN (letter case and underscores are ignored)
```

- Without its `-d:` switch a constant keeps its declared default.
- `{.flagDefine.}` makes a `bool`. It reads `truthySpellings` (`yes`, `1`,
  `on`, `true`) as `true` and `falsySpellings` (`no`, `0`, `off`, `false`,
  `none`) as `false`, in any letter case; a bare `-d:name` is `true`. (The
  name `boolDefine` is taken: Nim reads it as its built-in `{.booldefine.}`.)
- `{.enumDefine.}` makes a value of the declared enum type (or of the
  default's type when none is written). It accepts each value's name and,
  for an enum with string values, each value's string, ignoring letter case
  and underscores: `debug`, `Debug` and `DEBUG` all give `DEBUG`.
  `offValue = X` also reads every falsy spelling as `X`, after the enum's
  own names were tried.
- The define's name is the constant's name, unless given as the first
  argument (`{.flagDefine("mylib.traces").}`) or as `name = "..."`.
- Any other value is a compile error at the declaration, naming the option,
  the value and the values it accepts.

The parsing functions behind the macros are exported for run-time use with
the same spellings: `parseFlagValue`, `parseEnumValue[E]`, `isFalsyValue`
and `enumValueSpellings[E]`.

## Command lines described in clispec

Besides a plain configuration type, confutils can be instantiated over a
command line described in [clispec](https://github.com/metacraft-labs/nim-cli-spec),
a declarative description language for Nim command lines. Clispec generates
from the description the configuration type (subcommands are commands with
their own metadata, not enum values), the argv parser, help and shell
completion. Confutils adds what lies beyond the command line, reading what
each parameter declares from the description:

* configuration-file layers, in the order and with the bindingness the
  program declares, validated against a schema generated from the
  description;
* the environment variables a parameter's `env` names;
* per-parameter merge rules across those sources and the command line;
* an origin object recording where every value came from and what it
  overrode.

Parsing the command line, help and completion are delegated to the code
clispec generates, so a program's command line behaves the same whether it
reads configuration files or not.

The clispec integration needs Nim 2.0 or newer, the version nim-cli-spec
requires. Because confutils depends on nim-cli-spec, the confutils package
as a whole requires Nim 2.0 as well.

```nim
import std/[os, tables, tempfiles]
import confutils/clispec_config, confutils/layers/toml_source

proc strictest(candidates: openArray[CliSourcedValue[int]]): int =
  for c in candidates:
    result = max(result, c.value)

cliConfiguration(Tool, "tool"):
  configSchema "tool.config.v1"
  convention file = snakeCase
  flag jobs is int, default = 4, env = ["TOOL_JOBS"]
  flag searchPaths is seq[string], merge = append, separator = ":",
    env = ["TOOL_PATH"]
  flag level is int, merge = strictest
  flag token is string, sources = {env, file}, env = ["TOOL_TOKEN"]

let dir = createTempDir("tool_", "")
writeFile(dir / "system.toml", """
schema = "tool.config.v1"
jobs = 2
""")
writeFile(dir / "user.toml", """
schema = "tool.config.v1"
jobs = 6
level = 3
search_paths = ["/usr/share/tool"]

[extensions]
my_editor_settings = { theme = "dark" }
""")

let sources = CliSources(format: tomlCliFormat(),
  layers: @[
    CliLayer(name: "system", path: dir / "system.toml", binding: true),
    CliLayer(name: "user", path: dir / "user.toml"),
    CliLayer(name: "project", path: dir / "absent.toml")], # skipped
  env: {"TOOL_PATH": "/opt/tool", "TOOL_TOKEN": "t0k"}.toTable)

let (conf, origins) = Tool.loadWithOrigins(@["--jobs", "8"], sources)
assert conf.jobs == 2                     # the system layer enforces it
assert origins.jobs.kind == cokEnforced
assert origins.jobs.winner.layer == "system" and origins.jobs.winner.line == 2
assert origins.jobs.losers[1].fate == cfIgnoredByEnforcement # --jobs 8
assert conf.searchPaths == @["/usr/share/tool", "/opt/tool"]
assert conf.level == 3 and conf.token == "t0k"
echo cliDescribe(origins.jobs)
removeDir(dir)
```

`cliConfiguration` takes what clispec's `cliProgram` takes and generates
everything it does (`Tool`, `Tool.load(argv)`, `Tool.helpText`,
`Tool.complete`, ...), and also `Tool.load(argv, sources)`,
`Tool.loadWithOrigins(argv, sources)` and `Tool.configSchema`. A program
whose clispec model carries an extension generates the same code from its
own macro with clispec's `cliProgramCode` followed by
`cliConfigurationCode`.

#### Layers belong to the program

A `CliSources` lists the program's layers, lowest precedence first, each a
`CliLayer` with a `name` (what origins and errors call it), a `path`,
`binding` and `required` (a missing file is an error rather than a skipped
layer). Every value a **binding** layer sets is _enforced_: no other source,
the environment and the command line included, can override it, and each
attempt is recorded in the origin as ignored. When two binding layers set the
same key, the lower one enforces it. An enforced value ignores the merge
rule: it is not combined, appended or reported as a conflict.

The environment is a table the program passes in (`cliProcessEnv()` returns
the process's own); nothing reads the process environment behind its back.
An environment value is text, converted exactly like a command-line value; a
list parameter's variable is one element, or a delimited list when the
parameter declares a `separator`. A parameter reads exactly the variables its
`env` lists; no names are derived.

#### Merge rules

Each source (a layer, the environment, the command line) gives a parameter
one value: within one source a list collects every occurrence, a counted
flag adds them up and anything else keeps its last. Across sources:

| `merge`           | Value                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `replace`         | the highest source's (a higher source's list, even an empty one, replaces a lower one's)                                      |
| `append`          | every source's list concatenated, lowest first (a `seq` or counted parameter only)                                            |
| `errorOnConflict` | as `replace`, but two sources with different values are a `cekConflictingSources` error naming both (values compared as text) |
| a combine proc    | what the proc returns from every source's value                                                                               |

A combine proc has the signature
`proc (candidates: openArray[CliSourcedValue[T]]): T`, where `T` is the
parameter's type: it receives one `CliSourcedValue` per source that supplied
the parameter, lowest first, each with the converted `value` and its
`origin` (a `CliSite`). A proc that does not fit is a compile error naming
the parameter. If it raises, loading fails with `cekConflictingSources`
carrying its message.

Defaults and `implies` apply only after every source has been merged, so a
default never stands in for a value a file supplied.

#### Configuration files

A file is read by a format adapter, a `CliConfigFormat` whose `parse` proc
(`CliConfigParser`) turns the file's text into a flat list of entries, each
with its key's segments, its value (string, integer, float, bool, date-time
or array) and its line. `tomlCliFormat()` from `confutils/layers/toml_source`
reads TOML with
[nim-toml-serialization](https://github.com/status-im/nim-toml-serialization);
`confutils/clispec_config` does not import it, so a program without
configuration files needs no serialization library for it. An adapter for
another format implements the same proc.

The program's schema is then applied to the entries, for every format alike:

- The file must have a top-level `schema` string equal to the description's
  `configSchema`. A program without one loads no file.
- Every other key must be a parameter's configuration key, as the layer's
  source spells it, except keys under a top-level `extensions` table, which
  is the escape hatch for data the program does not define and is never
  read. The description sets each source's naming convention
  (`convention file = snakeCase`, `convention "project" = kebabCase`) and
  per-parameter overrides; a layer whose name is a file source the
  description declares uses that source's spelling; failing that, a layer
  whose format's name is one (`convention "toml" = ...`) uses that; any
  other layer uses the `file` source's. A key spelt in another source's
  convention is an unknown key.
- A value must have its parameter's type: a string (also for enums, paths
  and every type written as text), an integer, a float (an integer is
  accepted too) or a bool, and an array of those for a list parameter. A
  counted flag takes an integer.

Values are read verbatim: nothing is interpolated or expanded, and a list's
elements are never split on its `separator`. `Tool.configSchema` is the
schema as a value, with its keys spelt as the `file` source spells them, and
`Tool.configSchema("project")` the same for a named source; each key also
lists its spelling in every file source (`sourceKeys`). `cliConfigSchemaJson`
renders it as JSON under the schema name `clispec-config-schema/1` (keys are
only added within that name).

A file that breaks these rules raises a `CliConfigError`, whose `kind` is a
`CliConfigErrorKind`, each with one wording naming the file, the line and the
key where there is one:

| Kind                  | Wording                                                                        |
| --------------------- | ------------------------------------------------------------------------------ |
| `cfeUnknownKey`       | `/home/u/.config/tool.toml:4: unknown key 'jbos' (layer 'user')`               |
| `cfeMissingSchema`    | the file has no top-level `schema` string (the wording shows the expected one) |
| `cfeWrongSchema`      | `...:1: declares schema "tool.config.v2"; expected "tool.config.v1"`           |
| `cfeWrongType`        | `...:2: key 'jobs' has the string "four"; expected an integer`                 |
| `cfeSyntax`           | `...:3: is not valid:` followed by the format's own message                    |
| `cfeUnreadable`       | a required layer's file is missing, or a file cannot be read                   |
| `cfeNoSchemaDeclared` | the description declares no `configSchema`                                     |
| `cfeNoFormat`         | layers were given without a format                                             |

#### The origin object

`loadWithOrigins` also returns an object of the same shape as the
configuration object (`ToolOrigins`, `ToolBuildOrigins`, ..., with the same
`command` discriminator) holding a `CliOrigin` per field:

- `winner`, a `CliSite`: its `kind` (`cokDefault`, `cokFile` with `path`,
  `line`, `key` (as the file spelt it), the `layer` name and the
  `fileSource` whose convention that spelling is, `cokEnv` with the
  `variable`, `cokCli` with the `argvIndex` and `spelling` clispec's parser
  recorded, `cokImplied` with `impliedBy`, `cokEnforced` like a file, or
  `cokUnset`), also readable as `origin.kind`;
- `values`, the value as written;
- `losers`, every other value that was considered, in the order the merge
  considered them (layers lowest first, then the environment, then the
  command line), each with its `value`, its `site` and its `fate`:
  `cfOverridden`, `cfCombined` (part of an `append` or combined value) or
  `cfIgnoredByEnforcement`.

`cliDescribe(origin)` puts it in one line, for a debug report or an
`--explain` option.

#### Moving a configuration type onto a description

A program whose command line is a confutils configuration type can describe
it in clispec and keep both its help screens and its runtime surface:

```nim
import confutils/clispec_config

cliConfiguration(Tool, "tool"):
  boolFlag verbose is bool, short = 'v', default = false,
    help = "Print more"
  flag cacheDir is string, perSource = [cli = "cache-dir"],
    default = "/tmp/tool", defaultValueDesc = "$HOME/.cache/tool",
    help = "Where results are cached"
  call:
    discard
  subcmd "build":
    flag jobs is int, short = 'j', default = 4, help = "Parallel jobs"
    pos target is string, help = "What to build"

echo Tool.cliClassicHelp(["build"], copyrightBanner = "Tool 1.0")
Tool.showClassicHelp([])          # writes the help to stdout
let surface = Tool.surfaceFromModel("tool", defaultCommandName = "noCommand")
```

`cliClassicHelp(commandPath, programName, copyrightBanner, width)`
(`confutils/clispec_classic_help`, which `confutils/clispec_config`
exports) renders, byte for byte, the help `load` prints for the equivalent
type: the banner, the `Usage:` frame, the colours (none under
`-d:confutils_no_colors`), the abbreviation and name columns, the wrapping
(to `terminalWidth()` by default, which reads `COLUMNS` first), the
narrow-terminal layout, ` [=<default>].` after each description, the
positionals that end a command, and a block per subcommand. The equivalent
type declares the same parameters in the same order: a flag is a field
with that long `{.name.}`, `short = 'x'` is `{.abbr: "x".}` (a long
`alias = "--xy"` is `{.abbr: "xy".}`), `pos` is `{.argument.}`, a
`rest = true` positional is `{.restOfArgs.}`, `help` is `{.desc.}`,
`longHelp` is `{.longDesc.}`, `visibility = hidden` is `{.hidden.}`, the
subcommands are the values of an enum `{.command.}` discriminator declared
after the command's other fields, and `call:` is that discriminator's
`{.defaultValue.}`. A default is shown as its `default` expression is
written (a string literal unquoted), which is the text confutils shows for
`{.defaultValue.}`; `defaultValueDesc = "<text>"` is `{.defaultValueDesc.}`,
the text shown instead. It changes only this help and the surface; clispec's
own help shows the `default`.

`surfaceFromModel(programName, defaultCommandName)` is the
`RuntimeCommandSurface` `surfaceFromType` gives for the equivalent type:
global flags, commands, nested subcommands and each flag's short name,
description, type, `required` (no `default`), default text and value kind.
`surfaceFromType` lists the discriminator's default value as a command too;
a `call:` has no name, so it is listed, first, only under
`defaultCommandName`. Both procedures also take a `CliGrammar` in place of
the type (`Tool.cliClassicGrammar()` is the grammar with the
`defaultValueDesc` texts applied).

## Contributing

The development of Confutils is sponsored by [Status.im](https://status.im/)
through the use of [GitCoin](https://gitcoin.co/). Please take a look at our
tracker for any issues having the [bounty][BOUNTIES] tag.

When submitting pull requests, please add test cases for any new features
or fixes and make sure `nimble test` is still able to execute the entire
test suite successfully.

[BOUNTIES]: https://github.com/status-im/nim-confutils/issues?q=is%3Aissue+is%3Aopen+label%3Abounty

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.

