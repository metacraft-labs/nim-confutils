import
  std/options

type
  ConfigurationError* = object of CatchableError

  TypedInputFile*[ContentType = Unspecified,
                  Format = Unspecified,
                  defaultExt: static string] = distinct string

  # InputFile* = TypedInputFile[Unspecified, Unspecified, ""]
  # TODO temporary work-around, see parseCmdArg
  InputFile* = distinct string

  InputDir* = distinct string
  OutPath* = distinct string
  OutDir* = distinct string
  OutFile* = distinct string

  RestOfCmdLine* = distinct string
  SubCommandArgs* = distinct string

  Flag* = object
    name*: string

  FlagWithValue* = object
    name*: string
    value*: string

  FlagWithOptionalValue* = object
    name*: string
    value*: Option[string]

  Unspecified* = object
  Txt* = object

  SomeDistinctString = InputFile|InputDir|OutPath|OutDir|OutFile

template `/`*(dir: InputDir|OutDir, path: string): auto =
  string(dir) / path

template `$`*(x: SomeDistinctString): string =
  string(x)

template desc*(v: string) {.pragma.}
template longDesc*(v: string) {.pragma.}
template name*(v: string) {.pragma.}
template abbr*(v: string) {.pragma.}
template separator*(v: string) {.pragma.}
template defaultValue*(v: untyped) {.pragma.}
template defaultValueDesc*(v: string) {.pragma.}
template required* {.pragma.}
template command* {.pragma.}
template argument* {.pragma.}
template restOfArgs* {.pragma.}
template hidden* {.pragma.}
template ignore* {.pragma.}
template inlineConfiguration* {.pragma.}

template implicitlySelectable* {.pragma.}
  ## This can be applied to a case object discriminator
  ## to allow the value of the discriminator to be determined
  ## implicitly when the user specifies any of the sub-options
  ## that depend on the disciminator value.

# ---------------------------------------------------------------------------
# Runtime surface types (M6: Dynamic Runtime Extensions)
#
# These are plain value types that describe a CLI surface at runtime. They
# decouple the help / completion / usage algorithms from the compile-time
# typed-config style that confutils historically required: the algorithms
# operate on a ``RuntimeCommandSurface`` and the type is populated from any
# source (a Nim type via the compile-time bridge, a capability JSON file, a
# registry lookup, output parsed from ``ct-describe-commands``, etc.).
#
# Downstream consumers (e.g. the CodeTracer help delegate) construct the
# surface dynamically and call ``renderHelpFromSurface`` / completion / merge
# APIs without needing a Nim type at all. Existing confutils users see no
# behavioural change.
# ---------------------------------------------------------------------------

type
  RuntimeFlag* = object
    ## A single CLI flag described as plain data.
    name*: string        ## long form (without leading "--"), e.g. "log-level".
                         ##   The empty string means there is no long form.
    short*: char         ## short form (without leading "-"); '\0' means none.
    description*: string ## human-readable description.
    typeHint*: string    ## display type hint such as "INT", "PATH", "STRING";
                         ##   empty when no hint should be rendered.
    required*: bool      ## whether the flag is required.
    default*: string     ## rendered default value as displayed in help;
                         ##   empty string means "no default to display".

  RuntimeCommand* = object
    ## A command (or sub-command) described as plain data.
    name*: string                    ## the command name as typed on the CLI.
    description*: string             ## description for help output.
    flags*: seq[RuntimeFlag]         ## per-command flags.
    fileTypes*: seq[string]          ## file extensions (with leading dot)
                                     ##   the command can operate on, e.g. @[".py"].
    projectMarkers*: seq[string]     ## project-root markers (manifest files, etc.).
    note*: string                    ## dynamic annotation rendered alongside the
                                     ##   command (license status, deprecation, etc.).
    subcommands*: seq[RuntimeCommand]## sub-command tree.

  RuntimeCommandSurface* = object
    ## A whole CLI surface: program metadata, commands and global flags.
    programName*: string
    version*: string
    description*: string
    commands*: seq[RuntimeCommand]
    globalFlags*: seq[RuntimeFlag]
