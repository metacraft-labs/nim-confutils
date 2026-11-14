## test_cs_m4_unknown_key_rejected: a configuration file is validated
## against the schema generated from the program's description. An unknown
## key is an error naming the file, the line and the key; a file without
## the top-level ``schema`` string, or with another schema, is rejected; a
## value of the wrong type names its key and line; the ``extensions`` table
## is the escape hatch and is never read.
##
## Real TOML files in a temporary directory and the real ``Cfg`` program
## (``cs_m4_fixture``), read through the TOML adapter; nothing is mocked.

import std/[strutils, unittest]

import ./cs_m4_fixture

cliConfiguration(Plain, "plain"):
  flag jobs is int

proc loadError(path: string): ref CliConfigError =
  ## The error loading ``path`` as the layer ``user`` raises, or nil.
  try:
    discard Cfg.load(@[], sources([layer("user", path)]))
  except CliConfigError as e:
    return e

suite "test_cs_m4_unknown_key_rejected":
  let s = newScratch()

  test "an unknown top-level key names the file, line and key":
    let f = s.file("top.toml", header & "jobs = 2\n\njbos = 3\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.path == f
      check e.line == 4
      check e.key == "jbos"
      check e.layer == "user"
      check e.msg == f & ":4: unknown key 'jbos' (layer 'user')"

  test "an unknown key inside a table names its full key":
    let f = s.file("table.toml", header & "[build]\ntarget = \"x\"\nopt = 1\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.line == 4
      check e.key == "build.opt"

  test "a key spelt in another style than the declared one is unknown":
    let f = s.file("style.toml", header & "writeReport = \"r\"\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.key == "writeReport"

  test "a parameter that files may not supply has no key":
    let f = s.file("note.toml", header & "note = \"n\"\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.key == "note"

  test "a quoted key with a dot is one segment, not a table":
    let f = s.file("quoted.toml", header & "\"build.target\" = \"x\"\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.key == "\"build.target\""

  test "an array of tables is not a parameter's value":
    let f = s.file("aot.toml", header & "[[jobs]]\nn = 1\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeWrongType
      check e.line == 2
      check e.key == "jobs"

  test "a nested array of tables is rejected, except under extensions":
    # The pinned parser accepts `[[a.b]]` under `[[a]]`; validation rejects
    # the outer array as it rejects any array of tables, and the escape
    # hatch keeps accepting both.
    let f = s.file("nested_aot.toml", header &
      "[[runs]]\nn = 1\n[[runs.steps]]\nm = 2\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.line == 2
      check e.key == "runs"
    let ok = s.file("nested_ext.toml", header & "jobs = 3\n" &
      "[[extensions.runs]]\nn = 1\n[[extensions.runs.steps]]\nm = 2\n")
    check Cfg.load(@[], sources([layer("user", ok)])).jobs == 3

  test "a file without the top-level schema string is rejected":
    let f = s.file("noschema.toml", "jobs = 2\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeMissingSchema
      check e.path == f
      check "schema = \"cfg.config.v1\"" in e.msg

  test "a schema nested in a table is not the top-level schema":
    let f = s.file("nested.toml", "[build]\nschema = \"cfg.config.v1\"\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeMissingSchema

  test "a file of another schema is rejected":
    let f = s.file("other.toml", "schema = \"cfg.config.v2\"\njobs = 2\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeWrongSchema
      check e.line == 1
      check e.detail == "cfg.config.v2"
      check e.expected == "cfg.config.v1"

  test "a value of the wrong type names its key and line":
    let f = s.file("type.toml", header & "jobs = \"four\"\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeWrongType
      check e.line == 2
      check e.key == "jobs"
      check "expected an integer" in e.msg
    let g = s.file("list.toml", header & "tags = \"a\"\n")
    let e2 = loadError(g)
    check e2 != nil
    if e2 != nil:
      check e2.kind == cfeWrongType
      check "an array of strings" in e2.msg

  test "the extensions table is the escape hatch":
    let f = s.file("ext.toml", header & "jobs = 5\n\n[extensions]\n" &
      "anything = 1\nnested = { deep = [1, 2] }\n\n" &
      "[[extensions.items]]\nname = \"a\"\n")
    check Cfg.load(@[], sources([layer("user", f)])).jobs == 5

  test "a syntax error names the file and line":
    let f = s.file("syntax.toml", header & "jobs = 2\njobs = 3\n")
    let e = loadError(f)
    check e != nil
    if e != nil:
      check e.kind == cfeSyntax
      check e.path == f
      check e.line == 3

  test "the error comes before any value is used":
    # The command line is fine; the file is not, so nothing is loaded.
    let f = s.file("late.toml", header & "unknown = 1\n")
    expect CliConfigError:
      discard Cfg.load(@["--jobs", "2"], sources([layer("user", f)]))

  test "a program that declares no configSchema loads no file":
    let f = s.file("plain.toml", header)
    try:
      discard Plain.load(@[], sources([layer("user", f)]))
      check false
    except CliConfigError as e:
      check e.kind == cfeNoSchemaDeclared

  s.remove()
