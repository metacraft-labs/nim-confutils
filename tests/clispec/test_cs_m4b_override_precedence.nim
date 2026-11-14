## test_cs_m4b_override_precedence: a parameter's overrides refine the
## conversion, most specific first: its override for the source (for a
## named file source its own ``perSource`` entry, then ``key``, which is the
## override for every file source), then its override for the source's
## convention (``perConvention``), then the conversion.
##
## ``Ov`` declares the command line and the file source ``project`` in
## kebab-case, every other file and the file source ``legacy`` in snake_case,
## and parameters that each give a different mix of overrides. The test
## checks the spellings in the model, the library functions that decide
## them, and that loading actually finds each value under the decided
## spelling (and not under the losing one) for flags and for files.
##
## Real TOML files in a temporary directory, read through the TOML adapter;
## nothing is mocked.

import std/[json, unittest]

import ./cs_m4_fixture

cliConfiguration(Ov, "ov"):
  configSchema "ov.config.v1"
  convention cli = kebabCase
  convention file = snakeCase
  convention "project" = kebabCase
  convention "legacy" = snakeCase
  # Per convention only: every source with that convention uses it.
  flag urlBase is string,
    perConvention = [kebabCase = "base-url", snakeCase = "base_url"]
  # Per source beats per convention; the others fall back to it, then to
  # the conversion.
  flag httpPort is int,
    perConvention = [kebabCase = "http-port-number",
                     snakeCase = "http_port_number"],
    perSource = [cli = "port", "project" = "web.port"]
  # ``key`` is the override for every file source; a named source's own
  # entry beats it.
  flag cacheDir is string, key = "paths.cache",
    perSource = ["legacy" = "cache"]
  # ``key`` beats a per-convention override.
  flag logLevel is string, key = "logging.level",
    perConvention = [snakeCase = "lvl", kebabCase = "lvl"]
  call:
    help "Run"
  subcmd "remote":
    # A per-convention override replaces the last segment of a derived key.
    flag pushUrl is string, perConvention = [snakeCase = "push_uri"]

const ovHeader = "schema = \"ov.config.v1\"\n"

func keyIn(p: PlainCliParam; source: string): string =
  if source == "file":
    return p.configKey
  for k in p.sourceKeys:
    if k.source == source:
      return k.spelling

func param(name: string): PlainCliParam =
  for p in Ov.cliModel.root.params:
    if p.name == name:
      return p
  for c in Ov.cliModel.commands:
    for p in c.params:
      if p.name == name:
        return p

suite "test_cs_m4b_override_precedence":
  let s = newScratch()

  test "the library functions: per source, then per convention, then the conversion":
    let perSource = @[CliSourceSpelling(source: "cli", spelling: "port")]
    let perConvention = @[CliConventionSpelling(convention: cnKebabCase,
      spelling: "http-port-number")]
    check cliSpelling("httpPort", "cli", cnKebabCase, perSource,
      perConvention) == "port"
    check cliSpelling("httpPort", "cli", cnKebabCase, [],
      perConvention) == "http-port-number"
    check cliSpelling("httpPort", "cli", cnKebabCase) == "http-port"
    # Another source with the same convention takes the per-convention one.
    check cliSpelling("httpPort", "legacy", cnKebabCase, perSource,
      perConvention) == "http-port-number"
    let fileSource = @[CliSourceSpelling(source: "project",
      spelling: "web.port")]
    check cliSourceKey(["serve"], "httpPort", "project", cnKebabCase, "",
      fileSource, perConvention) == "web.port"
    check cliSourceKey(["serve"], "httpPort", "project", cnKebabCase,
      "a.b", fileSource, perConvention) == "web.port"
    check cliSourceKey(["serve"], "httpPort", "project", cnKebabCase,
      "a.b", [], perConvention) == "a.b"
    check cliSourceKey(["serve"], "httpPort", "project", cnKebabCase, "",
      [], perConvention) == "serve.http-port-number"
    check cliSourceKey(["serve"], "httpPort", "project", cnKebabCase, "",
      [], []) == "serve.http-port"

  test "per convention only":
    let p = param("urlBase")
    check p.longName == "base-url"
    check p.keyIn("file") == "base_url"
    check p.keyIn("project") == "base-url"
    check p.keyIn("legacy") == "base_url"

  test "per source beats per convention, for flags and files":
    let p = param("httpPort")
    check p.longName == "port"
    check p.keyIn("project") == "web.port"
    # No per-source entry: the per-convention override.
    check p.keyIn("file") == "http_port_number"
    check p.keyIn("legacy") == "http_port_number"

  test "a named source's own entry beats key, which beats the conversion":
    let p = param("cacheDir")
    check p.keyIn("file") == "paths.cache"
    check p.keyIn("project") == "paths.cache"
    check p.keyIn("legacy") == "cache"
    check p.longName == "cache-dir"

  test "key beats a per-convention override":
    let p = param("logLevel")
    check p.keyIn("file") == "logging.level"
    check p.keyIn("project") == "logging.level"
    # A long flag has no key: its convention's override applies.
    check p.longName == "lvl"

  test "a per-convention override replaces the last key segment":
    let p = param("pushUrl")
    check p.keyIn("file") == "remote.push_uri"
    check p.keyIn("legacy") == "remote.push_uri"
    check p.keyIn("project") == "remote.push-url"
    check p.longName == "push-url"

  test "the command line answers to the winning spelling only":
    let conf = Ov.load(@["--port", "8", "--base-url", "u", "--lvl", "d"])
    check conf.httpPort == 8
    check conf.urlBase == "u"
    check conf.logLevel == "d"
    for loser in ["--http-port-number", "--http-port", "--url-base",
                  "--log-level"]:
      try:
        discard Ov.load(@[loser, "1"])
        check false
      except CliUsageError as e:
        check e.kind == cekUnknownFlag

  test "files answer to the winning spelling only":
    let project = s.file("project.toml", ovHeader &
      "base-url = \"pu\"\npaths.cache = \"/c\"\n[web]\nport = 81\n")
    let legacy = s.file("legacy.toml", ovHeader &
      "base_url = \"lu\"\ncache = \"/l\"\nhttp_port_number = 82\n" &
      "logging.level = \"w\"\n[remote]\npush_uri = \"r\"\n")
    let (conf, origins) = Ov.loadWithOrigins(@["remote"],
      sources([layer("legacy", legacy), layer("project", project)]))
    check conf.httpPort == 81
    check origins.httpPort.winner.key == "web.port"
    check origins.httpPort.losers[0].site.key == "http_port_number"
    check conf.cacheDir == "/c"
    check origins.cacheDir.losers[0].site.key == "cache"
    check conf.urlBase == "pu"
    check conf.logLevel == "w"
    check conf.remote.pushUrl == "r"
    check origins.remote.pushUrl.winner.key == "remote.push_uri"
    # The losing spellings are unknown keys.
    for (layerName, line) in [("project", "http-port-number = 1\n"),
                              ("legacy", "web.port = 1\n"),
                              ("legacy", "paths.cache = \"x\"\n"),
                              ("user", "lvl = \"x\"\n"),
                              ("user", "[remote]\npush_url = \"x\"\n")]:
      let f = s.file("wrong.toml", ovHeader & line)
      try:
        discard Ov.load(@[], sources([layer(layerName, f)]))
        check false
      except CliConfigError as e:
        check e.kind == cfeUnknownKey

  test "help and the schema show the overridden spellings":
    let doc = parseJson(Ov.helpJson())
    var found = false
    for p in doc["command"]["parameters"]:
      if p["name"].getStr == "httpPort":
        found = true
        check p["spellings"] == %*["--port"]
        check p["configKeys"] == %*{"file": "http_port_number",
          "project": "web.port", "legacy": "http_port_number"}
    check found
    check Ov.configSchema("legacy").keys[2].key == "cache"
    check Ov.configSchema("project").keys[1].key == "web.port"

  s.remove()
