# Vision

`maak.el` is the Emacs front end to maak, and its whole premise is that a build
file written in Lisp deserves an editor that reads it as Lisp. The direction is
to close the loop that a `compile` buffer only half closes: from the task you
chose, to the prompt for its arguments, to the line of the Maak file that failed,
and back into the REPL — without ever asking maak to change what a task is.

## Where maak.el is today

One file, `maak.el`, 671 lines, Emacs 28.1 and later, `lexical-binding: t`, MIT.
Three commands: `maak-run-task` runs a task through `compile`, `maak-describe-task`
shows its docstring, command line and every argument with its kind and default,
and `maak-goto-task` opens the Maak file at the definition, pushing the xref
marker stack so `xref-go-back` returns. Two `defcustom`s (`maak-executable`,
`maak-annotation-padding`) and two faces that inherit from the theme's
`font-lock-variable-name-face` and `font-lock-doc-face`. 47 ERT tests, three
fixtures, and a CI matrix on Emacs 28.2, 29.4 and 30.1 that byte-compiles with
warnings as errors.

The parser is where the design lives. `maak-get-tasks` reads the file
structurally — top-level forms located by a syntax table that handles strings,
`;` comments, `#|...|#` block comments and `#;` datum comments — and never
evaluates it and never calls Guile's reader, because `#:optional` and `#;datum`
are syntax Emacs Lisp's reader would mangle. Two consequences follow from that
choice and constrain everything else.

**No Guile, no subprocess, no server.** The package answers from buffer text, so
it works on a machine with neither Guile nor maak installed, in a container, and
over a file just written by an agent. The suite needs no network, and the two
tests that do compare `maak.el`'s reading against `guile`'s arity and
`maak --list` skip when those are absent rather than fail.

**The front end cannot invent semantics.** A task is `(NAME DOCSTRING ARGUMENTS
POSITION)`, and the argument plist carries `:name`, `:kind` (`required`,
`optional`, `key`, `rest`), `:default`, `:default-p` and `:keyword` — exactly what
the lambda list says. The hard consequence is documented rather than papered
over: a keyword argument is displayed but never prompted for, because maak's
command line passes positional strings and nothing else, and a keyword argument
written without a default is refused before the run instead of failing in Guile
with `Missing keyword`.

## The vision

1. **The debug loop closes.** A task that fails lands the point on the task's
   definition in the Maak file, not at the top of a `*compilation*` buffer that
   says something a human must interpret. Today `next-error` has nothing to work
   with, because maak's `task-error` prints one line and a hint, and no `FILE:LINE`.

2. **The canonical front end is the most capable one.** `contrib/` ships dry-run,
   task-name completion and run-last for several of the seven other editors.
   `maak.el`, named first-class wherever maak is described, still has one command
   per intention and no dry run. Parity is owed in this direction, not the other
   way round.

3. **The file is the interface, wherever you are in it.** A `maak-mode` minor mode
   makes a Maak file navigable — imenu entries per task, `M-.` from a call site to
   the definition, a task at point to run — so the editor's ordinary Lisp reflexes
   work on the build the way they work on any other module.

4. **One description, one parser.** `maak.el` and `contrib/bin/maak-tasks` both
   parse a Maak file, and both must agree with `maak --list`. The direction is a
   test that compares all three, so a new lambda-list shape breaks one build
   instead of quietly disagreeing in seven editors.

5. **Prompting scales to the shapes Guile permits.** Optional arguments that are
   skipped leave later positional arguments unpassable, and a rest argument is one
   prompt split on whitespace. The direction is prompts that state these limits
   where they bite, and a story for keyword arguments the day maak can accept them.

## Features that are in scope and not built yet

- **Keyword arguments crossing the command line.** The plist already carries
  `:keyword`; what is missing is a maak that can accept `--key value` or
  `#:key=value`. The hard part is on maak's side, and `maak.el` must keep working
  against older maaks that would read such a word as a task or an argument.
- **A dry run.** `maak -n` prints shell commands instead of running them, which is
  a compile buffer's worth of value with none of the risk. The hard part is
  nothing technical and everything editorial: what the buffer should say a dry run
  meant.
- **Run last.** Every other integration has it; here it is missing. The hard part
  is where the last run lives — a buffer-local variable is wrong across projects,
  and a global one is wrong across two checkouts of the same project.
- **A second project root in view.** `maak-find-file` takes the nearest ancestor
  holding `maak.scm` and has no override. The hard part is a variable or a
  `.dir-locals` convention that does not become a second configuration surface.
- **Reading the file maak would read.** `maak -f FILE` and `maak -C DIR` change
  which file runs; this package always resolves `maak.scm` by walking up. The hard
  part is honouring `MAAK_ENV_FILE` and `-f` without executing anything.

## New features that would be worth having

- **Error locations.** Ask maak for `FILE:LINE:` on a failing task — behind
  `--debug`, or as a new structured line — then add an entry to
  `compilation-error-regexp-alist-alist` so `next-error` and `recompile` address
  the Maak file directly. This is speculative in the sense that it needs a change
  on the maak side, and it is the single largest improvement to the loop.
- **`maak-transient`.** A transient menu over run, dry run, describe, goto, and
  whichever task ran last — discovery, and no new semantics. The command set is
  small enough that it fits in one buffer without becoming a mode of its own.
- **`maak-run-task-at-point`**, for the point being inside a `define` in a Maak
  file or on a task call inside another task. The half that matters is recognising
  a task call rather than a definition.
- **Flymake integration** that flags a `maak.scm` whose `#:export` list names a
  procedure the file does not define — a real class of breakage that `maak --list`
  reports and the buffer does not.
- **A task skeleton command** that inserts a `define*` with a docstring and the
  documented argument shapes, so a new task starts from the same shape the parser
  understands rather than from memory.
- **A parallel run**: `maak -j N task1,task2` from the editor, with each task's
  output already arriving as one block because that is what maak does.
- **Embark actions** on a task at point, which is the cheapest way to make a
  two-variable package feel like it has a keymap.

## Contributions that would move the needle

1. **Dry run, run-last and their tests.** Small, self-contained, and it removes
   the one place where the canonical front end is behind `contrib/`. The suite
   already has the harness — `maak-command` is pure and testable — so this is a
   few functions and a handful of ERT tests.
2. **A three-way reading test.** Compare `maak-get-tasks` on
   `test/fixtures/grammar.scm` with `guile`'s own arity and with `maak --list`,
   in that order, skipping when absent. The fixtures already hold one exported
   task per lambda-list shape, so the test is mostly wiring.
3. **An imenu entry per task and an xref backend.** `maak-get-tasks` already
   returns `POSITION`, which is all either needs. This is the highest ratio of
   editor comfort to lines written in the whole package.
4. **`maak-mode` as a minor mode**, after the two above, so the file gets the
   navigation without the package claiming a major mode it does not need.
5. **The docs page that does not exist yet**: what a *failed* task looks like
   today, why the point does not move, and where to look instead. An honest page
   about a limitation outranks a feature that hides it.
6. **The maak-side change for error locations**, opened where it belongs, with the
   `compilation-error-regexp-alist` entry written and tested in this repository
   first.
7. **A tabulated or completing-read test matrix**, so the completion shape is
   covered against every framework the README names — Vertico, Ivy, Helm — instead
   of against the one the author uses.

## Compared to related projects

| Project | What it is | Where maak.el differs |
| --- | --- | --- |
| `justl` | An Emacs porcelain for `just`: lists recipes, runs them, and offers them as compile and transient commands. | `justl` asks the `just` binary for the list and evaluates the justfile's variables. `maak.el` parses the file structurally — no subprocess, no evaluation — so it works with maak absent and cannot disagree with a `just` that is a different version. |
| Geiser | A Scheme development environment in Emacs: REPL, module browser, symbol documentation, for Guile among others. | Geiser asks a live Guile about a live module. `maak.el` answers from the buffer's text, which is why it needs no running Scheme — and why it cannot see a task defined by a macro Geiser could have evaluated. |
| CIDER | The Clojure REPL-driven environment: nREPL connection, evaluation at point, test running, namespace browsing. | Same split, one language over: CIDER's world is a live image. maak's own `repl` task runs an Ares nREPL server, so a future `maak.el` could borrow CIDER's shape without borrowing its dependency. |
| `compile` and `project.el` | Emacs' own compilation buffer and project abstraction. | `maak.el` is built on both rather than replacing either: `compile` supplies `next-error`, `recompile` and the buffer, and `project.el` is the alternative to walking up for `maak.scm`. |
| `bazel.el` | Emacs integration for Bazel: run targets, jump to `BUILD` files, browse the query graph. | Bazel's model is a target graph, and its Emacs integration is mostly a graph viewer. maak has no targets, so `maak.el`'s object of study is the lambda list — a richer thing per task, a poorer thing per project. |
| `rustic` and `cargo-transient` | Cargo transient menus for Rust development in Emacs. | The command set there is hard-coded per package; `maak.el`'s set is read from the project, so there is nothing to enumerate in advance and nothing to fall behind. |
| `make-mode` | Emacs' built-in Makefile mode: font-lock, a compile command, and a target list from the text. | `make-mode` reads targets out of a file whose language it also fontifies. `maak.el` reads a Guile module `scheme-mode` already handles, and takes on the part `scheme-mode` cannot: arguments and their defaults. |

What the others do that `maak.el` could still add: `justl`'s transient menu and
task-at-point running are the discoverability layer this package lacks, and both
are cheap. CIDER's `next-error` story — an error in the buffer you were editing,
not in a program's output — is the pattern worth copying, which is why error
locations rank first in the speculative list. `bazel.el`'s habit of rendering the
build's own structure is a reminder that `maak.el` has a graph available and shows
none of it: `deploy` calling `fmt`, `test` and `deploy` is visible in the text and
invisible in the UI.

Where `maak.el` is ahead and should stay ahead: it needs no running build system,
no server, no socket and no daemon — the file is the interface; it understands
every lambda-list form Guile accepts, including the dotted rest argument and the
`lambda`-value definition, and refuses the impossible case out loud; it keeps the
editor's own `compile` machinery, so `recompile`, `next-error` and the whole
`compilation-mode` vocabulary keep working; and it is small enough to read in an
afternoon, which is the property that makes an editor integration trustworthy.

## In the long run

**Staying a reader is the bet.** The moment `maak.el` requires a Guile process,
it inherits Guile's installation, version, load path and start-up cost, and it
stops working on a laptop, in CI, and over a file nobody has evaluated yet. Every
feature that pushes towards evaluation has to earn it against that cost — and most
will not.

**The package is a consumer of a description, not of a program.** maak's own
direction is a machine-readable task description emitted by maak; when it exists,
`maak.el` should consume it for the cases a static reader cannot reach — tasks
defined through a macro, a conditional `#:export`, a module re-export — while
keeping the static reader as the fallback that works with nothing installed. The
two are complementary, not rival, and the three-way test is what keeps them
honest.

**The editor is where a build is understood.** A build you cannot read is a build
you cannot fix; a build you cannot navigate is one you will not read. In the long
run `maak.el` is the place where a Guile build becomes legible — definition,
signature, docstring, failure, and the two keystrokes between them.

## Getting involved

The suite is `maak ci`, or `emacs -Q --batch -L . -l test/maak-test.el -f
ert-run-tests-batch-and-exit` when maak is not installed. `AGENTS.md` — generated
from the practices pinned in `maak.scm` — is the repository's own rulebook and
wins over anything argued here.

*This document describes intent, not commitments: it names directions the project
would like to take, and no item in it is promised for any release.*
