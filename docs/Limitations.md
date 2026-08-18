# Known limitations of confutils

This is a catalogue of the confutils behaviours that downstream code has had to
work around. It exists to be *fixed*, not to be lived with: this is the
Metacraft Labs fork (`metacraft-labs/nim-confutils`), so every entry here is
ours to repair.

Each entry has a minimal, self-contained reproduction, the observed and the
expected behaviour, the downstream cost with real call sites, a fix sketch, and
a severity.

Every limitation below is also an **expected-red test** in
[`tests/test_known_limitations.nim`](../tests/test_known_limitations.nim), run
with:

```
nimble limitations
```

That suite is deliberately excluded from `tests/test_all.nim` and from
`nimble test`. See [Expected-red suite](#expected-red-suite) at the bottom for
what that means and how to retire an entry.

## Severity classes

| Class | Meaning |
|---|---|
| **Silently wrong** | The command line is accepted and means something other than what the user wrote. No diagnostic. This is the dangerous class: the damage is done before anyone knows there was a question. |
| **Loudly unsupported** | The construct is refused, with a message. Annoying and limiting, but honest. |
| **Loud but misdirected** | Refused, but the message points somewhere other than the cause — an internal assertion, a Nim runtime frame, or another program's name. Costs debugging time out of proportion to the defect. |

## Index

| # | Limitation | Severity |
|---|---|---|
| [L1](#l1--dash-prefixed-pass-through-arguments-are-rejected) | Dash-prefixed pass-through arguments are rejected | Loudly unsupported |
| [L2](#l2--the-posix----separator-is-ignored) | The POSIX `--` separator is ignored | **Silently wrong** |
| [L3](#l3--options-after-a-subcommands-positionals-are-claimed-by-the-parent) | Options after a subcommand's positionals are claimed by the parent | **Silently wrong** |
| [L4](#l4--restofargs-cannot-coexist-with-an-option-in-the-same-command) | `{.restOfArgs.}` cannot coexist with an option in the same command | Loudly unsupported |
| [L5](#l5--group-help-omits-the-default-sub-commands-own-invocation) | Group help omits the default sub-command's own invocation | **Silently wrong** (incomplete, with no sign it is incomplete) |
| [L6](#l6--usage-and-error-text-is-hard-coded-to-say-ct) | Usage and error text is hard-coded to say `ct` | **Silently wrong** |
| [L7](#l7--a-command-discriminator-requires--dnimoldcaseobjects) | A `{.command.}` discriminator requires `-d:nimOldCaseObjects` | Loud, at runtime, in shipped binaries |
| [L8](#l8--a-one-line-field-less-command-branch-aborts-the-macro) | A one-line field-less command branch aborts the macro | Loud but misdirected |
| [L9](#l9--quitonfailure--false-raises-an-empty-diagnostic) | `quitOnFailure = false` raises an empty diagnostic | Loud but misdirected |

---

## L1 — Dash-prefixed pass-through arguments are rejected

**Severity: loudly unsupported.**

### Minimal reproduction

```nim
type
  DemoCmd = enum
    noCommand
    run

  DemoConf = object
    case cmd {.command, defaultValue: noCommand.}: DemoCmd
    of noCommand:
      noCmdArgs {.ignore.}: string
    of run:
      program {.argument.}: string
      progArgs {.argument, defaultValue: @[].}: seq[string]

discard DemoConf.load(cmdLine = @["run", "php", "-S", "localhost:8000"])
```

### Observed

```
Unrecognized option 'S'
Try ct --help for more information.
```

`-S` belongs to `php`, not to us. The parse never reaches `progArgs`.

### Expected

`program == "php"` and `progArgs == @["-S", "localhost:8000"]`. A trailing
`seq[string]` positional in a subcommand whose job is to name and invoke
another program must be able to collect that program's argv verbatim.

That this is the right semantics is not a matter of taste: `{.restOfArgs.}`
in the same position already does exactly this — see L4, which is why it
cannot be used here.

### Consequence

Three whole command groups in CodeTracer are dispatched by hand before
confutils ever sees `argv`, each with its own argument parsing:

- `codetracer/src/ct/codetracer.nim:88-127` — `ct-complete` / `ct-completions`.
  The comment is explicit: *"confutils would otherwise try to parse those tokens
  as flags for `ct` itself and reject them with 'Unrecognized option'. We
  intercept the dispatch before confutils sees argv."*
- `codetracer/src/ct/codetracer.nim:106-114` with
  `codetracer/src/ct/review_cli.nim:336-353` (`reviewNeedsRawDispatch`) —
  `ct review collect|inspect|export`, because they *"take options that are not
  ct's own (`--repo`, `--diff-file`, `--preset`, …) and confutils rejects every
  dash-prefixed token it does not recognise."*
- `codetracer/src/frontend/viewmodel/agent_evidence.nim:231-241`
  (`dispatchAgentEvidenceCli`) — `ct agent evidence`.

Plus `codetracer/src/ct/db_backend_record.nim:525-560`, which hand-parses its
entire grammar rather than use confutils at all, and
`codetracer/src/ct/ci/bpf_native_integration_test.nim:332,360`, where a test
writes a temporary shell script instead of running `bash -c …` through `ct`:
*"Use a temp script instead of `bash -c` to avoid confutils parsing `-c` as a
ct option."*

The cost is not just the interception code. Each intercepted command now has
**two** entry points that must agree — `codetracer/src/ct/review_cli.nim:474-482`
exists solely to catch the two paths drifting apart — and none of the
intercepted commands appear in confutils-generated help or completion.

### Fix sketch

The parse loop is `loadImpl` in `confutils.nim:1193-1273`. The `cmdLongOption` /
`cmdShortOption` arm ends in `fail "Unrecognized option '$1'"`
(`confutils.nim:1241`). The information needed to do better is already in
scope: `lastCmd` knows whether it has a collecting (`seq[string]`) positional
and whether `nextArgIdx` has begun consuming it.

Two options, not mutually exclusive:

1. A command-level pragma — `{.passThrough.}` or reusing L4's `{.restOfArgs.}`
   once it is unblocked — that switches the command into "no more option
   parsing" mode once its first positional has been consumed.
2. Fixing L2 (`--`), which gives users an explicit, standard escape hatch even
   when the command is not declared pass-through.

Note that `getopt` is called with `shortNoVal = {}, longNoVal = @[]`
(`confutils.nim:1193`); a pass-through mode is better implemented by switching
to raw token consumption than by tuning those sets.

---

## L2 — The POSIX `--` separator is ignored

**Severity: silently wrong.**

### Minimal reproduction

Same `DemoConf` as L1, plus a parent-level option:

```nim
    deepreview {.defaultValue: "".}: string
```

```nim
let conf = DemoConf.load(cmdLine = @["run", "./prog", "--", "--deepreview", "x"])
```

### Observed

```
cmd=run  program="./prog"  progArgs=@[]  deepreview="x"
```

The bare `--` is dropped, and `--deepreview x` — which the user explicitly
fenced off — is consumed as the *parent's* option.

### Expected

`deepreview == ""` and `progArgs == @["--deepreview", "x"]`. POSIX Utility
Syntax Guideline 10 (<https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html>)
makes `--` the universal end-of-options marker, and Nim's own `parseopt` yields
it as an ordinary `cmdLongOption` token with an empty key rather than acting on
it.

This is worse than L1. L1 refuses to do something; L2 quietly does the opposite
of what the command line says, on the very construct a user reaches for to
prevent exactly that.

### Consequence

`codetracer/src/ct/codetracer.nim:131-181` implements `--` by hand: it splits
`commandLineParams()` at the first `--`, hands confutils only the left half,
and — because the required `recordProgram` positional now lives to the right of
the split where confutils cannot see it — injects a sentinel placeholder
(`"\0ct-record-child-program"`) so the parse succeeds, then overwrites the field
afterwards. The comment records both failure modes it was written to stop:
`ct record php -S localhost:8000` *"died with 'Unrecognized option S'"*, and,
worse, *"a child flag colliding with one of ct's own was ACCEPTED, so
`ct record php --version` printed CodeTracer's version, recorded nothing, and
exited 0."*

`codetracer/src/ct/review_cli.nim:144-160` then has to *re-implement* confutils'
scoping rules — including stopping at `--` — so that a hand-written scan for a
retired option does not misfire on a child program's identically-spelled flag.

### Fix sketch

In `loadImpl`'s token loop (`confutils.nim:1193`), detect the bare `--` token
and set a `noMoreOptions` flag; from then on every token is routed to the
`cmdArgument` arm regardless of its leading dashes. Nim's `parseopt` reports
`--` as `(kind: cmdLongOption, key: "", val: "")`, so the check is
`kind == cmdLongOption and key.len == 0`.

Interaction with L1: with `--` honoured, the L1 reproduction still fails
(`run php -S …` has no `--`), so both fixes are worth having.

---

## L3 — Options after a subcommand's positionals are claimed by the parent

**Severity: silently wrong. The most dangerous entry in this catalogue.**

### Minimal reproduction

Same `DemoConf` as L2.

```nim
let conf = DemoConf.load(
  cmdLine = @["--cwd", "/tmp", "run", "./prog", "--deepreview", "x"])
```

### Observed

```
cmd=run  cwd="/tmp"  program="./prog"  progArgs=@[]  deepreview="x"
```

### Expected

```
cmd=run  cwd="/tmp"  program="./prog"  progArgs=@["--deepreview", "x"]  deepreview=""
```

`--cwd` precedes the subcommand, so it is unambiguously the parent's.
`--deepreview` appears *after* `run`'s positional has begun collecting, so it
belongs to the collecting positional.

No diagnostic is produced in either reading. The user gets a program that ran
without the flag they passed it, and a parent that silently acted on a flag
they never addressed to it.

### Consequence

This is the "silent case" `codetracer/src/ct/codetracer.nim:131-140` calls
*"worse"* than the loud one, and it is why `ct record` splits argv itself.
It also forced `codetracer/src/ct/review_cli.nim:144-160` to encode a rule
about *where* a global option may legitimately appear, so that
`ct record ./prog --deepreview x` is not misreported as using a retired `ct`
option — parser semantics leaking into application code.

### Fix sketch

`findOpt(activeCmds, key)` at `confutils.nim:1217` searches the active command
stack innermost-first and falls back to the parent
(`confutils.nim:446-450`). That fallback is what claims the token. The
positional cursor `nextArgIdx` already tells the loop whether the active
command has started consuming positionals, and `acceptsMultipleValues`
(`fieldSetters[idx][4]`) tells it whether the current positional is a
collecting `seq[string]`.

Minimal fix: once the active command's *collecting* positional has begun,
stop searching ancestor commands for option names and route the token to that
positional. Strictly-safer alternative if the semantics are considered
ambiguous: keep the current behaviour but make it an error rather than a silent
choice — anything but resolving it quietly.

Do not fix this by making the parent's option merely lose priority to a
same-named subcommand option; `checkDuplicate` (`confutils.nim:740`) already
rejects that collision at compile time, and it is not the case that bites.

---

## L4 — `{.restOfArgs.}` cannot coexist with an option in the same command

**Severity: loudly unsupported.**

### Minimal reproduction

```nim
type
  ExecCmd = enum
    noCommand
    exec

  ExecConf = object
    case cmd {.command, defaultValue: noCommand.}: ExecCmd
    of noCommand:
      noCmdArgs {.ignore.}: string
    of exec:
      quiet {.defaultValue: false.}: bool          # <-- one ordinary option
      program {.argument.}: string
      rest {.restOfArgs, defaultValue: @[].}: seq[string]
```

### Observed

Compile-time:

```
confutils.nim(870, 15) cmdInfoFromType
tests/limitations/restofargs_with_flag.nim(50, 7)
  Error: not supported: non-required args before {.restOfArgs.}: rest
```

Deleting the `quiet` field makes it compile, and `restOfArgs` then does the
right thing: `exec php -S localhost:8000` yields
`rest == @["-S", "localhost:8000"]`.

### Expected

The configuration compiles. `{.restOfArgs.}` is the only construct in confutils
that forwards dash-prefixed tokens verbatim, so it is precisely what a
pass-through subcommand needs — and a pass-through subcommand almost always has
at least one flag of its own. Refusing the combination refuses the use case.

### Consequence

`codetracer/src/ct/codetracerconf.nim:731-739` spells out the workaround and
its cause:

> *"this cannot be `{.restOfArgs.}` even though that is exactly what it is.
> confutils rejects `restOfArgs` in any command that also has flags: its check
> walks EVERY option, not just the positional ones, and requires each to be a
> required Arg (nim-confutils.nim ~line 866 — the `previousOpt.kind == Arg`
> half of the condition is commented out). `run` gets away with `restOfArgs`
> only because it declares no flags."*

Same workaround at `codetracer/src/ct/codetracerconf.nim:1081-1090` and
`:1138-1147` for `ct ci exec` / `ct ci run`, and recorded in
`codetracer/.agents/codebase-insights.txt:229`. Falling back to a plain
`argument seq[string]` is what re-exposes those commands to L1, L2 and L3 —
this limitation is the root cause of the `--` machinery, not an independent
inconvenience.

### Fix sketch

The check is `confutils.nim:864-871`:

```nim
if optKind == RestOfArgs:
  for i, previousOpt in cmd.opts:
    let isRequired = not previousOpt.hasDefault
    let isRequiredArg = isRequired and previousOpt.kind == Arg
    if not isRequiredArg: # and previousOpt.kind == Arg:
      error "not supported: non-required args before {.restOfArgs.}: " & opt.name
```

The commented-out `and previousOpt.kind == Arg` on the last line is the fix the
original author started and did not finish: the loop should skip options that
are not positionals (`previousOpt.kind != Arg`) instead of rejecting them. The
runtime side already tolerates this — `findRestOfArgs` (`confutils.nim:438-449`)
only requires `restOfArgs` to be the last option of `seq[string]` type.

The runtime cut-over at `confutils.nim:1199-1207` needs auditing at the same
time: it triggers on `index >= lastCmd.opts.len`, an index arithmetic that
counts *all* options, and it reads `paramStr`/`paramCount` directly rather than
the `cmdLine` it was given — so it ignores an explicitly-passed `cmdLine`,
which alone makes the behaviour untestable in-process. Both must change
together.

---

## L5 — Group help omits the default sub-command's own invocation

**Severity: silently wrong — the help is incomplete and gives no sign of it.**

### Minimal reproduction

```nim
type
  ReviewCmd = enum
    launch
    collect

  DemoConf = object
    case cmd {.command, defaultValue: noCommand.}: DemoCmd
    ...
    of review:
      case reviewCmd {.command, defaultValue: launch.}: ReviewCmd
      of launch:
        dataset {.argument, desc: "Dataset to open".}: string
      of collect:
        repo {.defaultValue: "", desc: "Repository to collect from".}: string
```

```
$ ./app review --help
```

### Observed

```
Usage:

ct review command

Available sub-commands:

ct review collect [OPTIONS]...

The following options are available:

 --repo  Repository to collect from.
```

`review`'s default sub-command — `launch`, and its `<dataset>` argument, the
form most users will actually type — appears nowhere. Neither does any hint
that the listing is partial.

### Expected

The help lists **every** form of `review`, default sub-command included:

```
ct review <dataset>          Dataset to open
ct review collect [OPTIONS]...
```

### Consequence

CodeTracer reports the mirror image of this: `ct review --help` prints only the
launch form and never mentions `collect` / `inspect`. That specific symptom is
downstream of **L1**, not of this entry — `collect` and `inspect` are
intercepted before confutils, so confutils genuinely does not know they exist —
but the effect on the user is identical, and the two compose: whichever half of
a command group confutils knows about, group help will be missing part of it.

Every command group in CodeTracer therefore hand-writes its own group usage:
`codetracer/src/ct/review_cli.nim` (`ReviewUsage`),
`codetracer/src/ct/launch/launch.nim:420-421` (*"No CI subcommand specified"*),
`codetracer/src/ct/launch/launch.nim:547-548` (*"ct trace: no subcommand
specified"*). `codetracer/src/ct/cli/help.nim:5-9` goes further and implements
`ct help` by re-spawning the binary with `--help`, because confutils exposes no
way to render help programmatically (`showHelp` is private and calls
`flushOutputAndQuit`, `confutils.nim:375-403`).

### Fix sketch

`describeOptions` at `confutils.nim:359-373`:

```nim
let defaultCmdIdx = subCmdDiscriminator.defaultSubCmd
if defaultCmdIdx != -1:
  let defaultCmd = subCmdDiscriminator.subCmds[defaultCmdIdx]
  help.describeOptions defaultCmd, cmdInvocation, appInfo, defaultCmdOpts   # options only

helpOutput fgSection, "\pAvailable sub-commands:\p"
for i, subCmd in subCmdDiscriminator.subCmds:
  if i != subCmdDiscriminator.defaultSubCmd:                                 # skipped
    ...
```

The default sub-command gets `describeOptions` but never `describeInvocation`,
so its usage line and its `<arguments>` are dropped. Calling
`describeInvocation defaultCmd, cmdInvocation, appInfo` before the
`describeOptions` call fixes the omission; the `i != defaultSubCmd` skip in the
listing loop is then correct, because the default form has already been shown
in its proper place.

For the CodeTracer-shaped half of the problem, the fork's own
`RuntimeCommandSurface` (`confutils/runtime_surface.nim`, added in `3bf016c`)
is the right vehicle: let a program register externally-handled verbs into the
surface so group help can document commands confutils does not itself parse.
That is also what would let `codetracer/src/ct/launch/help_delegate.nim:84-90`
stop bolting descriptions on after the fact.

---

## L6 — Usage and error text is hard-coded to say `ct`

**Severity: silently wrong. Fork-local regression.**

### Minimal reproduction

Any config, any binary that is not CodeTracer:

```
$ ./pass_through_app definitely-not-a-subcommand
ct has no such subcommand
Try ct --help for more information.
```

### Observed

Every usage line, every `Try … --help` suggestion and every
`noMoreArgsError` names `ct`, whatever the program is actually called.

### Expected

The messages name the running binary — `pass_through_app has no such
subcommand`, `Try pass_through_app --help for more information.` — which is
what upstream does.

### Consequence

This fork is shared. Any program that vendors it inherits CodeTracer's name in
its own diagnostics and tells its users to run a program they do not have.
Because the text is plausible, nobody notices until a user follows the advice.

### Fix sketch

`confutils.nim:102`:

```nim
else:
  template appInvocation: string = "ct"
```

Upstream (`origin/master:confutils.nim:101-105`):

```nim
else:
  template appInvocation: string =
    try:
      getAppFilename().splitFile.name
    except OSError:
      ""
```

The change came in with *"bugfix(codetracer): hardcode ct as the name of the
application so that implementation details are not shown"* — the real problem
being that CodeTracer's `ct` is a wrapper and `getAppFilename()` reports the
unwrapped executable. Restore the upstream body and give `load` an
`appName = ""` parameter (falling back to `getAppFilename().splitFile.name`)
so CodeTracer can pass `"ct"` explicitly. That serves the original need without
imposing it on every other consumer.

---

## L7 — A `{.command.}` discriminator requires `-d:nimOldCaseObjects`

**Severity: loud, but at runtime, in shipped binaries.**

### Minimal reproduction

Compile any config with a `{.command.}` discriminator *without* the define, and
run it with a subcommand:

```
$ nim c -o:app tests/limitations/pass_through_app.nim
$ ./app run ./prog
confutils.nim(1052) loadImpl
confutils.nim(709) cmdSetter
system/assign.nim(298) FieldDiscriminantCheck
Error: unhandled exception: assignment to discriminant changes object branch;
  compile with -d:nimOldCaseObjects for a transition period [FieldDefect]
```

Adding `-d:nimOldCaseObjects` makes it work. The behaviour is identical under
`--mm:refc`, `--mm:arc` and `--mm:orc`.

### Expected

The binary parses `run ./prog` and exits 0, with no define required. A CLI
library must not force a deprecated language-transition flag onto every program
that uses it — the flag is global, it changes case-object semantics across the
*entire* program, and it has been "for a transition period" since Nim 0.20.

### Consequence

`codetracer/src/Tuprules.tup:13` carries `-d:nimOldCaseObjects` for the whole
of CodeTracer for this reason. The failure mode for a new consumer is a
runtime crash in a released binary, on the first user who types a subcommand —
not a compile error.

### Fix sketch

`cmdSetter` at `confutils.nim:709` assigns the discriminator in place:

```nim
when `configField` is enum:
  if isSome(val):
    `configField` = parseEnumNormalized[type(`configField`)](val.get)
```

Nim has forbidden in-place branch transitions since 0.20; the supported
construction is to build a fresh object with the discriminator set at
initialisation. Two viable shapes:

1. Parse the whole command line into an intermediate, discriminator-free
   representation, then construct the `Configuration` object once, in a single
   `Configuration(cmd: chosen, …)` expression.
2. Keep the two-pass structure but have `loadImpl` create a new object as soon
   as the discriminator is decided, copying already-applied parent fields
   across — the discriminator is always known before any branch field can be
   set, because a branch field cannot be named until its command has been
   activated.

`(1)` is the real fix. The `CaseTransition` warnings the fork currently emits at
`confutils.nim:709` are the compiler pointing at exactly this line.

---

## L8 — A one-line field-less command branch aborts the macro

**Severity: loud but misdirected.**

### Minimal reproduction

```nim
    case cmd {.command, defaultValue: noCommand.}: PlainCmd
    of noCommand: discard          # one line
    of greet:
      who {.argument.}: string
```

### Observed

```
confutils/config_file.nim(172, 7) traverseOfBranch
lib/std/assertions.nim(40, 13) raiseAssert
lib/system/fatal.nim(62, 5) sysFatal
Error: unhandled exception: [OfBranch] Unsupported child node:
NilLit [AssertionDefect]
```

Writing the *same* branch across two lines —

```nim
    of noCommand:
      discard
```

— compiles and behaves identically.

### Expected

Both spellings compile. Source layout must not decide whether a type is
accepted, and a rejected type must be reported at the declaration that caused
it.

### Consequence

`of X: discard` is the natural way to say "this command takes nothing", so
authors hit this early and have nothing to go on: the stack trace names
`system/fatal.nim`, not their code. CodeTracer's workaround is a family of
unused filler fields tagged `{.ignore.}` —
`codetracer/src/ct/codetracerconf.nim:262-264` (`noCmdArgs`), `:444-447`
(`helpArgs`), `:1401-1408` (`ctDescribeCommandsArgs`, `ctHelpArgs`) — which look
like dead code to every subsequent reader.

Note that `{.ignore.}` filler fields must also be **exported** (`noCmdArgs*`),
or `generateSecondarySources` fails with `undeclared field: 'noCmdArgs'`. That
is the same defect wearing a different hat.

### Fix sketch

One line, in `confutils/config_file.nim:162-172`:

```nim
proc traverseOfBranch(ofBranch: NimNode, parent: ConfFileSection): ConfFileSection =
  for child in ofBranch:
    case child.kind:
    of nnkIdent, nnkDotExpr, nnkAccQuoted: discard
    of nnkRecList: result.children.add traverseRecList(child, result)
    else: raiseAssert "[OfBranch] Unsupported child node:\n" & child.treeRepr
```

Nim represents a one-line empty record-case branch as an `nnkOfBranch` holding
an `nnkNilLit`. `traverseRecList` twenty lines below (`config_file.nim:193`)
already has `of nnkNilLit: discard` for precisely this; `traverseOfBranch` was
never given the same arm. Add it.

While there: the three `raiseAssert` sites in this file should become
`error(msg, node)` so the diagnostic points at the user's declaration instead of
into the Nim runtime.

---

## L9 — `quitOnFailure = false` raises an empty diagnostic

**Severity: loud but misdirected.**

### Minimal reproduction

```nim
try:
  discard DemoConf.load(
    cmdLine = @["run", "php", "-S", "localhost:8000"],
    quitOnFailure = false, printUsage = false)
except ConfigurationError as err:
  echo "error: ", err.msg      # -> "error: "
```

### Observed

`err.msg` is the empty string. The real diagnostic (`Unrecognized option 'S'`)
is produced only on the branch that also terminates the process.

### Expected

`err.msg` carries the same text the terminating path prints.

### Consequence

`quitOnFailure = false` exists so an application can embed confutils and report
failures its own way — but it can only report *that* something failed, never
what. Combined with L6, a library consumer's only route to a usable message is
to let confutils print it, which means letting confutils call `quit`.

This is also why CLI behaviour in CodeTracer is only observable by launching a
whole binary, which in turn is why `codetracer/src/ct/review_cli.nim:23-46`
splits itself into a pure argv planner and an effectful executor, and why
`codetracer/src/ct_test/release_gate.nim:350-362,398-412` resorts to *reading
source files* to assert CLI behaviour: *"the wiring lives in confutils
declarations and a pre-parser interception that only exist in a linked `ct`, so
reading the sources is the only headless way to assert the retired option is
really gone."*

### Fix sketch

`confutils.nim:1034-1040`:

```nim
template fail(args: varargs[untyped]) =
  if quitOnFailure:
    errorOutput args
    errorOutput "\p"
    suggestCallingHelp()
  else:
    # TODO: populate this string
    raise newException(ConfigurationError, "")
```

The `TODO` is the fix. `errorOutput` already appends to a string buffer in the
help path (`helpOutput` / `help` in `loadImpl`); route `fail`'s varargs through
the same formatting into a local `string` and use it as the exception message,
so both branches render identically and there is one formatter, not two.

---

## Further gaps, catalogued but not yet reduced to a test

These come from the same survey of downstream workarounds. They are real —
each cites the code that pays for them — but each needs an API decision before
a test can assert the *correct* behaviour, so none is in the expected-red suite
yet.

| Gap | Evidence |
|---|---|
| No mutually-exclusive option groups / cross-field validation | `codetracer/src/ct/codetracerconf.nim:1443-1506` (`customValidateConfig`) hand-checks that at most one of `--last-matching / --id / --trace-folder / --interactive` is set. The normalised result then has to be stashed in a global, because the parsed config is immutable at the use site: `codetracer/src/ct/globals.nim:9-13`. |
| No conditionally-compiled fields | `codetracer/src/ct/codetracerconf.nim:337-339`: *"This should be put behind a `when defined(linux)` condition, but Confutils doesn't support this."* |
| No hidden **commands** (only hidden options) | `OptInfo.isHidden` is honoured (`confutils.nim:321`), `CmdInfo.isHidden` (`confutils.nim:35`) is never set and never read. CodeTracer maintains a hard-coded blacklist instead: `codetracer/src/ct/launch/help_delegate.nim:189-214`, and a matching TODO at `codetracer/src/ct/codetracerconf.nim:131`. |
| No programmatic help rendering | `showHelp` is private and ends in `flushOutputAndQuit` (`confutils.nim:375-403`). `codetracer/src/ct/cli/help.nim:5-9` implements `ct help` by re-spawning the binary with `--help`. |
| Per-command descriptions / metadata are not carried by the compile-time bridge | `codetracer/src/ct/launch/help_delegate.nim:84-90,178-185` re-attaches them after `surfaceFromType`; `codetracer/src/ct/codetracerconf.nim:158-159` (*"TODO handle descriptions of commands"*). |
| Copyright banner is prefix-only | `codetracer/src/ct/codetracer.nim:169-171`. |
| No shell-completion generation for a nested surface | `codetracer/src/ct/launch/help_delegate.nim:799-838,983-1030` re-implements flag/path completion and per-shell script emission by hand. |
| Value escaping unverified | `codetracer/src/ct/codetracerconf.nim:7-9`: *"TODO check if the values with special characters are parsed correctly by confutils."* |

---

## Expected-red suite

[`tests/test_known_limitations.nim`](../tests/test_known_limitations.nim)
contains one test per entry above, each asserting the **correct** behaviour.
All of them fail today. That is the design.

```
nimble limitations
```

The task exits non-zero. It is excluded from `tests/test_all.nim` and from
`nimble test`, so the ordinary suite stays green and CI is unaffected.

### Rules

- **Never** relax a test here to match today's behaviour. A test that encodes
  the defect turns a defect into a specification, which is worse than having no
  test at all.
- If a test here goes **green**, the limitation was fixed (or the test drifted).
  In the same change: move the test into `tests/test_all.nim`'s reach, and
  delete the entry from this document.
- New limitation? Add the entry here *and* the test there, in one commit, with
  a severity assigned.

### A note on running the suite

`nimble test` currently cannot build `tests/test_all.nim` in a clean checkout —
`confutils/std/net.nim` imports `stew/shims/net`, which no longer exists in
stew 0.5.1, the version the `.nimble` requirements resolve to. That failure is
unrelated to this document and predates it. The limitations suite does not
import that module and builds on its own.

### Fixtures

`tests/limitations/` holds the fixture programs the suite compiles and runs as
subprocesses. Some behaviour is only observable from a child process: help text
is written straight to stdout before `quit` (L5), a configuration that fails
`configurationRtti` cannot be imported at all (L4, L8), and a `FieldDefect`
aborts whichever process hits it (L7). No mocks are used anywhere in the suite —
the real compiler, the real `load`, real binaries.
