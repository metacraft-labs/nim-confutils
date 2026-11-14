## test_cs_m4b_per_source_convention: each source spells a parameter's name
## in its own naming convention, set once per source in the description.
##
## ``Svc`` spells every configuration file in snake_case, the file source
## named ``project`` in kebab-case and the command line's long flags in
## kebab-case. One parameter is read from a snake_case TOML layer, a
## kebab-case second layer and the command line, and is found under each
## source's spelling; the origin names the spelling each value was found
## under and the source whose convention it is. A layer whose name is not a
## declared source but whose format's name is takes that source's
## convention, and a layer's own name wins over its format's. Help, the
## machine-readable help, the configuration schema and the environment are
## checked too.
##
## Negative controls: a file using another source's spelling is rejected as
## an unknown key, and the declared spelling on the command line is an
## unknown flag.
##
## Real TOML files in a temporary directory, read through the TOML adapter;
## the environment is a table passed to the loader. Nothing is mocked.

import std/[json, strutils, unittest]

import ./cs_m4_fixture

cliConfiguration(Svc, "svc"):
  configSchema "svc.config.v1"
  convention file = snakeCase
  convention "project" = kebabCase
  convention cli = kebabCase
  flag writeReport is string, env = ["SVC_REPORT_PATH"]
  boolFlag dryRun is bool, negatable = true
  flag maxJobs is int, default = 1, short = 'j'
  call:
    help "Serve"
  subcmd "remote":
    flag pushUrl is string

cliConfiguration(ByFormat, "byformat"):
  configSchema "svc.config.v1"
  convention "toml" = camelCase
  convention "system" = snakeCase
  flag writeReport is string

const svcHeader = "schema = \"svc.config.v1\"\n"

proc loadError(sources: CliSources; argv: seq[string] = @[]):
    ref CliConfigError =
  try:
    discard Svc.load(argv, sources)
  except CliConfigError as e:
    return e

suite "test_cs_m4b_per_source_convention":
  let s = newScratch()
  let user = s.file("user.toml", svcHeader &
    "write_report = \"user\"\nmax_jobs = 2\n[remote]\npush_url = \"u\"\n")
  let project = s.file("project.toml", svcHeader &
    "write-report = \"project\"\nmax-jobs = 3\n[remote]\npush-url = \"p\"\n")

  test "the model spells each source in its convention":
    const m = Svc.cliModel
    check m.keyStyle == cnSnakeCase
    check m.flagConvention == cnKebabCase
    check m.fileSources == @[CliSourceConvention(source: "project",
      convention: cnKebabCase)]
    let p = m.root.params[0]
    check p.name == "writeReport"
    check p.longName == "write-report"
    check p.configKey == "write_report"
    check p.sourceKeys == @[CliSourceSpelling(source: "project",
      spelling: "write-report")]
    var push: PlainCliParam
    for c in m.commands:
      if c.name == "remote":
        push = c.params[^1]
    check push.name == "pushUrl"
    check push.configKey == "remote.push_url"
    check push.sourceKeys[0].spelling == "remote.push-url"

  test "one parameter from a snake_case layer, a kebab-case layer and the command line":
    let (conf, origins) = Svc.loadWithOrigins(
      @["--write-report", "cli", "remote", "--push-url", "c"],
      sources([layer("user", user), layer("project", project)]))
    check conf.writeReport == "cli"
    let o = origins.writeReport
    check o.winner.kind == cokCli
    check o.winner.spelling == "--write-report"
    check o.losers.len == 2
    check o.losers[0].site.kind == cokFile
    check o.losers[0].site.layer == "user"
    check o.losers[0].site.key == "write_report"
    check o.losers[0].site.fileSource == "file"
    check o.losers[0].value == "user"
    check o.losers[1].site.layer == "project"
    check o.losers[1].site.key == "write-report"
    check o.losers[1].site.fileSource == "project"
    check o.losers[1].value == "project"
    check conf.remote.pushUrl == "c"
    check origins.remote.pushUrl.winner.spelling == "--push-url"
    check origins.remote.pushUrl.losers[0].site.key == "remote.push_url"
    check origins.remote.pushUrl.losers[1].site.key == "remote.push-url"

  test "the kebab-case layer wins over the snake_case one below it":
    let (conf, origins) = Svc.loadWithOrigins(@[],
      sources([layer("user", user), layer("project", project)]))
    check conf.writeReport == "project"
    check conf.maxJobs == 3
    check origins.writeReport.winner.kind == cokFile
    check origins.writeReport.winner.key == "write-report"
    check origins.writeReport.winner.fileSource == "project"
    check origins.maxJobs.winner.key == "max-jobs"
    check origins.maxJobs.losers[0].site.key == "max_jobs"

  test "a layer that is not a named source uses the file convention":
    let (conf, origins) = Svc.loadWithOrigins(@[],
      sources([layer("system", user)]))
    check conf.writeReport == "user"
    check origins.writeReport.winner.key == "write_report"
    check origins.writeReport.winner.fileSource == "file"

  test "short spellings and negation follow the command line's convention":
    let conf = Svc.load(@["--dry-run", "-j", "5"])
    check conf.dryRun
    check conf.maxJobs == 5
    check not Svc.load(@["--dry-run", "--no-dry-run"]).dryRun

  test "environment variables are used exactly as declared":
    let conf = Svc.load(@[], sources([], [("SVC_REPORT_PATH", "env")]))
    check conf.writeReport == "env"

  test "negative control: a snake_case key in the kebab-case layer is unknown":
    let wrong = s.file("project-wrong.toml", svcHeader &
      "write_report = \"x\"\n")
    let e = loadError(sources([layer("project", wrong)]))
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.key == "write_report"
      check e.layer == "project"
      check e.line == 2

  test "negative control: a kebab-case key in a snake_case layer is unknown":
    let wrong = s.file("user-wrong.toml", svcHeader &
      "[remote]\npush-url = \"x\"\n")
    let e = loadError(sources([layer("user", wrong)]))
    check e != nil
    if e != nil:
      check e.kind == cfeUnknownKey
      check e.key == "remote.push-url"

  test "negative control: the declared spelling is not a flag":
    expect CliUsageError:
      discard Svc.load(@["--writeReport", "x"])
    try:
      discard Svc.load(@["--write_report", "x"])
      check false
    except CliUsageError as e:
      check e.kind == cekUnknownFlag

  test "a layer named after no source takes its format's convention":
    let camel = s.file("camel.toml", svcHeader & "writeReport = \"c\"\n")
    let snake = s.file("snake.toml", svcHeader & "write_report = \"s\"\n")
    let (conf, origins) = ByFormat.loadWithOrigins(@[],
      sources([layer("user", camel)]))
    check conf.writeReport == "c"
    check origins.writeReport.winner.fileSource == "toml"
    # The layer's own name wins over its format's.
    let (conf2, origins2) = ByFormat.loadWithOrigins(@[],
      sources([layer("system", snake)]))
    check conf2.writeReport == "s"
    check origins2.writeReport.winner.fileSource == "system"
    # And the format's convention rejects the other spelling.
    try:
      discard ByFormat.load(@[], sources([layer("user", snake)]))
      check false
    except CliConfigError as e:
      check e.kind == cfeUnknownKey
      check e.key == "write_report"

  test "help shows the command line's spelling":
    let text = Svc.helpText()
    check "--write-report <string>" in text
    check "--[no-]dry-run" in text
    check "-j, --max-jobs <int>" in text
    check "writeReport" notin text
    check "--push-url <string>" in Svc.helpText(["remote"])

  test "the machine-readable help shows every source's spelling":
    let doc = parseJson(Svc.helpJson())
    check doc["conventions"] == %*{"cli": "kebabCase", "file": "snakeCase",
      "project": "kebabCase"}
    var found = false
    for p in doc["command"]["parameters"]:
      if p["name"].getStr == "writeReport":
        found = true
        check p["spellings"] == %*["--write-report"]
        check p["configKeys"] == %*{"file": "write_report",
          "project": "write-report"}
      if p["name"].getStr == "dryRun":
        check p["negation"].getStr == "--no-dry-run"
    check found

  test "the configuration schema is spelt per source":
    let fileSchema = Svc.configSchema
    check fileSchema.source == "file"
    check fileSchema.convention == cnSnakeCase
    check fileSchema.keys[0].key == "write_report"
    let projectSchema = Svc.configSchema("project")
    check projectSchema.source == "project"
    check projectSchema.convention == cnKebabCase
    check projectSchema.keys[0].key == "write-report"
    check projectSchema.keys[^1].key == "remote.push-url"
    let doc = parseJson(cliConfigSchemaJson(projectSchema))
    check doc["schema"].getStr == "clispec-config-schema/1"
    check doc["source"].getStr == "project"
    check doc["conventions"]["cli"].getStr == "kebabCase"
    check doc["keys"][0]["key"].getStr == "write-report"
    check doc["keys"][0]["sourceKeys"] == %*{"file": "write_report",
      "project": "write-report"}

  s.remove()
