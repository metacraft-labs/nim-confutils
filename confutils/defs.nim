import
  std/options

type
  ConfigurationErrorKind* = enum
    ## What went wrong, so that a caller which does not quit on failure
    ## (`load(..., quitOnFailure = false)`) can word the error itself.
    cekOther              ## anything not classified below
    cekUnknownOption      ## a switch that no field declares
    cekMissingValue       ## a value-taking switch with nothing after it
    cekInvalidValue       ## `parseCmdArg` rejected the value (`detail` says why)
    cekUnexpectedArgument ## a positional argument the command does not take
    cekMissingRequired    ## a required option was not given
    cekHelpRequested      ## `--help` / `-h` (raised instead of printing help)
    cekVersionRequested   ## `--version` (raised instead of printing it)

  ConfigurationError* = object of CatchableError
    ## `msg` is always a complete English sentence.  The fields below carry
    ## the same facts in structured form; they are empty where they do not
    ## apply (an error raised by a config-file reader is `cekOther`).
    kind*: ConfigurationErrorKind
    option*: string     ## the switch as typed (`--name`, `-n`), or the
                        ## positional argument for `cekUnexpectedArgument`
    optionName*: string ## the declared long name of the matched option
    value*: string      ## the value that was rejected (`cekInvalidValue`)
    detail*: string     ## the underlying message, e.g. `parseCmdArg`'s
                        ## `ValueError` for `cekInvalidValue`

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

template implicitValue*(v: string) {.pragma.}
  ## The value an option takes when it is given bare (`--name`), or when the
  ## token after it is not a valid value of the field's type (or begins with
  ## `-`).  `--name=value` always applies `value`; `--name value` consumes the
  ## next token only when `parseCmdArg` accepts it.  This is how an option
  ## with an OPTIONAL value is declared, e.g. `--trace[=auto|off]`.

template alsoSets*(field: string, value: string) {.pragma.}
  ## When this option is given, `value` is ALSO applied to the field named
  ## `field` (its Nim identifier), at the same position in the command line,
  ## through that field's own setter.  A `seq` field therefore accumulates
  ## it in command-line order with the field's own option, and a scalar field
  ## takes whichever of the two spellings came last.  For a `bool` option the
  ## value is applied only when the option is set to true.  The target may be
  ## an `{.ignore.}` field, which then records the fact without being an
  ## option of its own.

template valueName*(v: string) {.pragma.}
  ## The placeholder shown for the option's value in help (`--output <path>`).

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
    longDescription*: string ## the ``longDesc`` pragma: further paragraphs,
                         ##   one per line, rendered under ``description``.
    aliases*: seq[string]## further long spellings (a multi-character
                         ##   ``abbr``), without the leading "--".
    takesValue*: bool    ## false for a switch (a ``bool`` field).
    valueOptional*: bool ## the value may be omitted (``implicitValue``).
    valueName*: string   ## the ``valueName`` pragma: the value placeholder.

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
