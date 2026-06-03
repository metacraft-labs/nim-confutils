## Runtime surface algorithms for confutils (M6).
##
## This module implements help formatting, usage text assembly, completion
## generation, surface merging, and a JSON construction helper that operate
## entirely on plain-data :type:`RuntimeCommandSurface` / :type:`RuntimeCommand`
## / :type:`RuntimeFlag` values. The same algorithms power:
##
## * the existing compile-time typed-config style (via the
##   ``surfaceFromType`` bridge implemented in ``confutils.nim``); and
## * fully dynamic surfaces built at runtime from arbitrary data sources
##   (capability descriptions, registry lookups, parsed text, JSON, etc.).
##
## The output format is deliberately uncoloured plain text -- callers that
## need terminal escape sequences can post-process the rendered output. The
## tests in the M6 verification suite assert against the plain-text form.

import
  std/[strutils, json]

import
  ./defs

export defs

# ---------------------------------------------------------------------------
# Field-equality / lookup helpers
# ---------------------------------------------------------------------------

func sameFlag*(a, b: RuntimeFlag): bool =
  ## Two flags are considered the same when they share their long name (when
  ## present) or short name. This is the matching used by :proc:`merge`.
  if a.name.len > 0 and b.name.len > 0:
    return a.name == b.name
  if a.short != '\0' and b.short != '\0':
    return a.short == b.short
  false

func sameCommand*(a, b: RuntimeCommand): bool =
  ## Commands compare by name. Empty-named commands never match (so they
  ## are never collapsed when merging anonymous surfaces).
  a.name.len > 0 and a.name == b.name

# ---------------------------------------------------------------------------
# Construction helpers (Deliverable: "API for constructing
# RuntimeCommandSurface from arbitrary runtime data")
# ---------------------------------------------------------------------------

func newRuntimeFlag*(
    name: string;
    short = '\0';
    description = "";
    typeHint = "";
    required = false;
    default = ""): RuntimeFlag =
  ## Convenience constructor for :type:`RuntimeFlag`.
  RuntimeFlag(
    name: name, short: short, description: description,
    typeHint: typeHint, required: required, default: default)

func newRuntimeCommand*(
    name: string;
    description = "";
    flags: seq[RuntimeFlag] = @[];
    fileTypes: seq[string] = @[];
    projectMarkers: seq[string] = @[];
    note = "";
    subcommands: seq[RuntimeCommand] = @[]): RuntimeCommand =
  ## Convenience constructor for :type:`RuntimeCommand`.
  RuntimeCommand(
    name: name, description: description, flags: flags,
    fileTypes: fileTypes, projectMarkers: projectMarkers,
    note: note, subcommands: subcommands)

func newRuntimeCommandSurface*(
    programName: string;
    version = "";
    description = "";
    commands: seq[RuntimeCommand] = @[];
    globalFlags: seq[RuntimeFlag] = @[]): RuntimeCommandSurface =
  ## Convenience constructor for :type:`RuntimeCommandSurface`.
  RuntimeCommandSurface(
    programName: programName, version: version,
    description: description, commands: commands, globalFlags: globalFlags)

# ---------------------------------------------------------------------------
# Help formatting (Deliverable: "Move help formatting algorithm to operate on
# RuntimeCommandSurface")
# ---------------------------------------------------------------------------

func flagSwitches*(flag: RuntimeFlag): string =
  ## Render the switch column for a flag, e.g. ``-l, --log-level``.
  if flag.short != '\0' and flag.name.len > 0:
    "-" & flag.short & ", --" & flag.name
  elif flag.short != '\0':
    "-" & flag.short
  elif flag.name.len > 0:
    "    --" & flag.name
  else:
    ""

func renderFlagLine*(flag: RuntimeFlag, namesWidth: int): string =
  ## Render a single flag line. The width of the switch column is padded to
  ## ``namesWidth`` characters so flags align in a table.
  let switches = flagSwitches(flag)
  result = " " & switches
  if switches.len < namesWidth:
    result.add spaces(namesWidth - switches.len)
  result.add "  "
  if flag.required:
    result.add "(required) "
  if flag.typeHint.len > 0:
    result.add "<" & flag.typeHint & "> "
  if flag.description.len > 0:
    result.add flag.description
  if flag.default.len > 0:
    result.add " [default: " & flag.default & "]"

func maxFlagSwitchLen(flags: seq[RuntimeFlag]): int =
  for f in flags:
    let w = flagSwitches(f).len
    if w > result: result = w

func renderFlagsSection*(flags: seq[RuntimeFlag], heading: string): string =
  ## Render a block of flags with a heading. Returns an empty string when
  ## the flag list is empty.
  if flags.len == 0: return ""
  result.add heading
  result.add ":\n"
  let namesWidth = max(maxFlagSwitchLen(flags), 4)
  for f in flags:
    result.add renderFlagLine(f, namesWidth)
    result.add "\n"

func renderCommand*(cmd: RuntimeCommand, indent = 0): string =
  ## Render a single command (recursively including its subcommands and
  ## flags). ``indent`` is the indentation depth in spaces (used for nested
  ## subcommands).
  let pad = spaces(indent)
  result.add pad & cmd.name
  if cmd.description.len > 0:
    result.add "  " & cmd.description
  if cmd.note.len > 0:
    # The note is the dynamic annotation rendered in-line with the command.
    # M6 verification ``test_confutils_dynamic_notes`` asserts the note is
    # present alongside the command in the rendered help.
    result.add "  [" & cmd.note & "]"
  result.add "\n"
  if cmd.fileTypes.len > 0:
    result.add pad & "  File types: " & cmd.fileTypes.join(", ") & "\n"
  if cmd.projectMarkers.len > 0:
    result.add pad & "  Project markers: " & cmd.projectMarkers.join(", ") & "\n"
  if cmd.flags.len > 0:
    let flagsText = renderFlagsSection(cmd.flags, pad & "  Options")
    result.add flagsText
  for sub in cmd.subcommands:
    result.add renderCommand(sub, indent + 2)

func renderHelpFromSurface*(surface: RuntimeCommandSurface): string =
  ## Render a full help screen from a :type:`RuntimeCommandSurface` value.
  ##
  ## The output is plain text suitable for both terminal display and string
  ## assertions in tests. It includes the program name and version line,
  ## the description, the global-flags section, and each command in turn
  ## (with subcommands rendered recursively).
  let progName = if surface.programName.len > 0: surface.programName else: "<program>"
  result.add progName
  if surface.version.len > 0:
    result.add " " & surface.version
  result.add "\n"
  if surface.description.len > 0:
    result.add surface.description & "\n"
  result.add "\n"
  if surface.globalFlags.len > 0:
    result.add renderFlagsSection(surface.globalFlags, "Global options")
    result.add "\n"
  if surface.commands.len > 0:
    result.add "Commands:\n"
    for cmd in surface.commands:
      result.add renderCommand(cmd, indent = 2)

func renderUsageFromSurface*(surface: RuntimeCommandSurface): string =
  ## Render a one-line "Usage:" string for the surface.
  ##
  ## Implements the "Move usage text assembly to operate on
  ## RuntimeCommandSurface" deliverable.
  let progName = if surface.programName.len > 0: surface.programName else: "<program>"
  result.add "Usage: " & progName
  if surface.globalFlags.len > 0:
    result.add " [GLOBAL OPTIONS]"
  if surface.commands.len > 0:
    result.add " <command>"
    result.add " [OPTIONS]..."

# ---------------------------------------------------------------------------
# Completion generation (Deliverable: "Move completion generation to operate
# on RuntimeCommandSurface")
# ---------------------------------------------------------------------------

func collectFlagTokens(flags: seq[RuntimeFlag], dest: var seq[string]) =
  for f in flags:
    if f.name.len > 0:
      dest.add "--" & f.name
    if f.short != '\0':
      dest.add "-" & $f.short

func collectCommandTokens(cmd: RuntimeCommand, dest: var seq[string]) =
  if cmd.name.len > 0:
    dest.add cmd.name
  collectFlagTokens(cmd.flags, dest)
  for sub in cmd.subcommands:
    collectCommandTokens(sub, dest)

func completionCandidates*(surface: RuntimeCommandSurface): seq[string] =
  ## Return the full set of completion candidates for a surface.
  ##
  ## Long-form flags are prefixed with ``--``, short-form flags with ``-``.
  ## Each command (and recursively each sub-command) contributes its name
  ## and its flags to the candidate list. The order is stable across calls
  ## so callers can rely on it for snapshot-style tests.
  collectFlagTokens(surface.globalFlags, result)
  for cmd in surface.commands:
    collectCommandTokens(cmd, result)

func completionsMatching*(
    surface: RuntimeCommandSurface, prefix: string): seq[string] =
  ## Return only the candidates that start with ``prefix``. Useful as the
  ## final hook for shell-completion drivers.
  for cand in completionCandidates(surface):
    if cand.startsWith(prefix):
      result.add cand

# ---------------------------------------------------------------------------
# Merge API (Deliverable: "API for constructing RuntimeCommandSurface from
# arbitrary runtime data" + verification ``test_confutils_runtime_merge``).
# ---------------------------------------------------------------------------

func mergeFlags*(a, b: seq[RuntimeFlag]): seq[RuntimeFlag] =
  ## Union two flag lists. When two flags collide (same long or short name)
  ## the entry from ``b`` wins.
  result = a
  for nf in b:
    var replaced = false
    for i in 0 ..< result.len:
      if sameFlag(result[i], nf):
        result[i] = nf
        replaced = true
        break
    if not replaced:
      result.add nf

func mergeCommands*(a, b: seq[RuntimeCommand]): seq[RuntimeCommand]

func mergeCommand*(a, b: RuntimeCommand): RuntimeCommand =
  ## Merge two same-named commands. The description / note / type metadata
  ## from ``b`` wins when non-empty; flags and subcommands are merged
  ## recursively.
  result = a
  if b.description.len > 0: result.description = b.description
  if b.note.len > 0: result.note = b.note
  if b.fileTypes.len > 0: result.fileTypes = b.fileTypes
  if b.projectMarkers.len > 0: result.projectMarkers = b.projectMarkers
  result.flags = mergeFlags(a.flags, b.flags)
  result.subcommands = mergeCommands(a.subcommands, b.subcommands)

func mergeCommands*(a, b: seq[RuntimeCommand]): seq[RuntimeCommand] =
  result = a
  for nc in b:
    var merged = false
    for i in 0 ..< result.len:
      if sameCommand(result[i], nc):
        result[i] = mergeCommand(result[i], nc)
        merged = true
        break
    if not merged:
      result.add nc

func merge*(a, b: RuntimeCommandSurface): RuntimeCommandSurface =
  ## Combine two surfaces. Commands and global flags are union'd
  ## per :proc:`sameCommand` / :proc:`sameFlag`; scalar metadata
  ## (program name, version, description) from ``b`` wins when non-empty.
  result = a
  if b.programName.len > 0: result.programName = b.programName
  if b.version.len > 0: result.version = b.version
  if b.description.len > 0: result.description = b.description
  result.globalFlags = mergeFlags(a.globalFlags, b.globalFlags)
  result.commands = mergeCommands(a.commands, b.commands)

# ---------------------------------------------------------------------------
# JSON construction (Deliverable: "API for constructing RuntimeCommandSurface
# from arbitrary runtime data")
# ---------------------------------------------------------------------------

proc flagFromJson*(node: JsonNode): RuntimeFlag =
  ## Build a :type:`RuntimeFlag` from a JSON description. Recognised fields:
  ##
  ## * ``name``        -- long-form name (default "").
  ## * ``short``       -- single-character short form (default '\0').
  ## * ``description`` -- description text.
  ## * ``typeHint``    -- display type hint.
  ## * ``required``    -- boolean.
  ## * ``default``     -- default-value text.
  ##
  ## Unknown fields are ignored so the format remains forward-compatible.
  if node.hasKey("name"): result.name = node["name"].getStr()
  if node.hasKey("short"):
    let s = node["short"].getStr()
    if s.len > 0: result.short = s[0]
  if node.hasKey("description"): result.description = node["description"].getStr()
  if node.hasKey("typeHint"): result.typeHint = node["typeHint"].getStr()
  if node.hasKey("required"): result.required = node["required"].getBool()
  if node.hasKey("default"): result.default = node["default"].getStr()

proc commandFromJson*(node: JsonNode): RuntimeCommand =
  ## Build a :type:`RuntimeCommand` from JSON. See :proc:`flagFromJson` for
  ## the flag schema; sub-commands recurse via this same procedure.
  if node.hasKey("name"): result.name = node["name"].getStr()
  if node.hasKey("description"): result.description = node["description"].getStr()
  if node.hasKey("note"): result.note = node["note"].getStr()
  if node.hasKey("flags"):
    for f in node["flags"].items:
      result.flags.add flagFromJson(f)
  if node.hasKey("fileTypes"):
    for f in node["fileTypes"].items:
      result.fileTypes.add f.getStr()
  if node.hasKey("projectMarkers"):
    for m in node["projectMarkers"].items:
      result.projectMarkers.add m.getStr()
  if node.hasKey("subcommands"):
    for s in node["subcommands"].items:
      result.subcommands.add commandFromJson(s)

proc surfaceFromJson*(node: JsonNode): RuntimeCommandSurface =
  ## Build a :type:`RuntimeCommandSurface` from a JSON object. This is the
  ## entry point the help delegate uses when reading capability descriptions
  ## or registry data from disk.
  if node.hasKey("programName"): result.programName = node["programName"].getStr()
  if node.hasKey("version"): result.version = node["version"].getStr()
  if node.hasKey("description"): result.description = node["description"].getStr()
  if node.hasKey("globalFlags"):
    for f in node["globalFlags"].items:
      result.globalFlags.add flagFromJson(f)
  if node.hasKey("commands"):
    for c in node["commands"].items:
      result.commands.add commandFromJson(c)

# ---------------------------------------------------------------------------
# Convenience accessors -- needed by the help-delegate and by the
# compile-time bridge tests.
# ---------------------------------------------------------------------------

func findCommandIdx*(
    surface: RuntimeCommandSurface, name: string): int =
  ## Locate a top-level command by name. Returns -1 when not found.
  for i in 0 ..< surface.commands.len:
    if surface.commands[i].name == name:
      return i
  -1

func findFlagIdx*(flags: seq[RuntimeFlag], name: string): int =
  ## Locate a flag by long-form name. Returns -1 when not found.
  for i in 0 ..< flags.len:
    if flags[i].name == name:
      return i
  -1

func hasCommand*(surface: RuntimeCommandSurface, name: string): bool =
  findCommandIdx(surface, name) >= 0

func hasFlag*(flags: seq[RuntimeFlag], name: string): bool =
  findFlagIdx(flags, name) >= 0
