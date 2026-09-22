# AGENTS.md — Aubade

Rules and policy for coding agents on the Aubade codebase — not
session records or measurements. User-facing documentation lives in
README.md.

# Project description

## Overview

Aubade is an MCP code-intelligence server written in **Odin** (single binary
`aubade`, entry point `src/main.odin`). One binary serves two run modes that
share the same tool implementations:

- **Child (MCP server)** `aubade mcp --project <path>`: one lightweight
  process per MCP client session. Speaks MCP over stdio and forwards work to
  the parent over RPC.
- **Parent daemon** `aubade daemon`: one per project (singleton, flock-guarded
  spawn). Owns the LSP clients, tree-sitter caches, editor buffers, SQLite,
  and shadow git. Exits when all children are gone (heartbeat liveness).

### Package layout and dependency direction

`src/` is a single collection (imports use the `src:` prefix). Dependencies
flow one way only:

```
foundation: core:* / vendor:* + handwritten packages (jsonrpc, jsonutil,
            mcp, rpc, platform — pure Odin; store, ts — wrap the vendored C libraries)
  ↑ config, prompt, safety
  ↑ domain: tracker, memory, symbol, editor
  ↑ services: lsp, lsproc, langserver, web, shadow, svc, hooks
  ↑ tools
  ↑ hosts: session, daemon, cli
```

- Lower layers must not import upper layers. When tempted to break a cycle,
  define a small port procedure type on the consumer side — never park a
  fat interface on the provider side in a lower layer.
- Process-global variables are forbidden. Application state lives on the
  `App` (child) / `Daemon` (parent) structs and is passed explicitly.
- The `domain` layer must not touch `thread`/`os` directly (testability).
  Concurrency and processes belong to the services/hosts layers.
- Tool implementations never cross the `svc` boundary — tools call svc
  procedures and know nothing about project state internals.

# Project principles

These principles govern every part below; each one names the sections
that carry its rules.

- **Correctness, processing performance, and resource behaviour are the
  product.** A change that trades any of them for convenience or
  deadline is a defect. Enforced in: Design rules; Build, link, and
  check; Odin language and stdlib.
- **The specification governs the implementation.** Where code and
  specification disagree, one of them is defective — determine which,
  and fix that side. Enforced in: Config, deployment, and spec.
- **Ground truth over confident recall.** Aubade exists because models
  mistake the lark for the nightingale; work in this repo holds the
  same bar — every fact is read from the current tree (or the current
  spec) before it is reported. Enforced in: Research principles (all
  sessions); Config, deployment, and spec.
- **Structure is load-bearing.** Dependencies flow one way, the process
  boundary is real, and every rule has exactly one home — one
  declaration, one visibility fold, one conventions skill. Enforced in:
  Package layout and dependency direction; Design rules; Coding
  conventions live in a skill.
- **Every resource has one owner and one bound.** There is no GC safety
  net: lifetimes are explicit, caches are bounded, and ownership
  transfers are visible at the call site. Enforced in: Design rules;
  Odin language and stdlib.
- **Verdicts come from artifacts.** Suite outcomes, memory figures, and
  incident resolutions are read from logs, measurements, and recorded
  evidence — never from exit codes, memory, or cross-compilation.
  Enforced in: Build, test, commit; Testing conventions; Cross-platform
  file handling.
- **Write for the next reader.** Comments state constraints the code
  cannot show, names carry their weight, and no text cites material
  the reader does not have. Enforced in: Comment self-containment.
- **Dogfood the product.** This repo is developed through aubade's own
  symbol, edit, and tracker tools; the friction you feel is the
  roadmap. Enforced in: Self-hosting: use Aubade on Aubade.

## Research principles (all sessions)

Grounding rules for anything reported to the user. They override harness
defaults that favour delegation or compressed summaries.

- Every `file:line` cited in a report must have been read directly in this
  session (Read/Grep or aubade's symbol tools). Facts sourced from
  sub-agent (Explore) output are not reportable until re-grounded against
  the code.
- Terminology is verified before use: quote an identifier only after
  grepping it in this repo. Unverified sub-agent vocabulary is verified or
  dropped — never relayed as fact.
- File references name the repo and the absolute path.
- A reported finding is answered with its grounding — one line of file:line
  or command output; the record is corrected when new evidence displaces it,
  and restating the same evidence changes nothing.
- A plan-mode mandate to use only Explore sub-agents does not override the
  symbol-tool exploration rule in the Self-hosting section; when they
  conflict, prefer grounded direct lookups.

## Comment self-containment

Committed code, docs, and error strings must be self-contained: no
citations of private notebooks or design docs, no chapter references
(`02 §5`), decision-record numbers (`ADR-20`), or local machine paths
like `~/src/...` in comments, doc headers, error messages, or anomaly
texts — every such citation dangles for readers without the referenced
material. State the constraint in prose where it matters. (Ported code
keeps its MIT provenance line — project name and license, no local
paths.)

The same discipline bounds the figures written here: exact numbers that
move while the code evolves (call-site counts, bundled-grammar counts,
suite sizes, constant default values) rot between edits, and session
measurements (timings, peak RSS, binary sizes) are records, not rules.
Where a magnitude carries a rule, write it as about/over/under and name
the identifier that owns the exact value.

# Development guide

## Coding conventions live in a skill

The Odin coding conventions — naming, error-model vocabulary, and
structural idioms — are also maintained as a skill, tracked at
`examples/skills/odin-conventions/SKILL.md`. If your harness supports
skills, load it when writing, reviewing, or renaming Odin code. If it
does not, read the file directly, or confirm with the user and rewrite
it into your harness's format. AGENTS.md's Design rules remain the
source of truth; the skill is its loadable mirror — change a rule in
both or not at all.

## Build, test, commit

```sh
just build        # C artifacts (tools/build) → odin build src -collection:src=src
just check        # odin check src -vet -strict-style
just test         # odin test tests (ODIN_TEST_THREADS=1)
just parsers go,odin      # partial grammar build (development)
```

- Prefer the just recipes over raw odin commands — `just test` already passes
  `-define:ODIN_TEST_THREADS=1`; wrap long runs as `timeout 600 just test`
  rather than spelling out the underlying odin invocation. The odin compile
  step is the suite's memory high-water mark (gigabyte-scale peak RSS), so
  keep the `systemd-run --user --scope -p MemoryMax=8G timeout 900 ...`
  wrapper as cheap insurance (an uncapped runaway still endangers the
  desktop session), require free memory well above that peak (≈2.5× —
  a margin, not a hard gate), run one compile at a time, and retry a run
  that flakes before investigating it.

- `odin build` does not compile C. The C artifacts (tree-sitter, the
  bundled grammars, SQLite, PCRE2, lexbor) are produced by `tools/build` into
  `lib/<os>_<arch>/`. lexbor is a git submodule
  (`git submodule update --init third_party/lexbor` after a clone);
  the other vendored C sources are tracked under `third_party/` — see its
  README for pins, licences, and bump procedures, and note
  `odin run tools/build -- verify-checksums` checks the vendored bytes
  against `third_party/CHECKSUMS.txt` (re-emit with `emit-checksums` after
  an intentional change; CI runs the verify). `lib/` is untracked —
  deleting it is safe, but a full grammar
  rebuild is slow (avoid it via incremental builds and the CI cache). All
  grammar objects merge into a single `libtree-sitter-grammars.a` (see
  the foreign-import caveat below); the linked binary is dominated by
  the grammars' const parse tables (`.rodata`) — compiler flags cannot
  shrink it, and unused grammars' pages never become resident.
- The Odin compiler tracks the **latest nightly** (currently
  `dev-2026-09-nightly:a2fb372`). CI pins the frozen dev-YYYY-MM
  release via `setup-odin` (`release: dev-2026-09`) plus a hard
  version-assert gate; if a nightly breaks the build, re-pin both to the
  last known-good release. This nightly ships no `odin fmt`
  subcommand — there is no formatter step; re-check after a compiler
  update.
- The Windows toolchain is **MSVC-only** (x64 Native Tools / Visual Studio
  Developer Command Prompt). Do not use MinGW. Cross-compiling Windows from
  Linux does not exist as a supported path (the link step is MinGW-bound) —
  Windows verification happens on Windows runners with native builds.
- Commits are English conventional style (`fix:`, `feat:`, ...); one
  comprehensive topical commit per change is the norm.

## Self-hosting: use Aubade on Aubade

Sessions in this repo run with the aubade MCP server attached
(`--project-from-cwd` resolves here; `.aubade/project.jsonc` configures
the repo's language servers, and the tracker store lives under
`.aubade/tracker/`). If it is not attached, install and register it
first: `scripts/build_install.sh` (installs to `~/.local/bin`; Windows:
`%LOCALAPPDATA%\Programs\aubade`; `AUBADE_INSTALL_DIR` overrides) then
`aubade setup <client>` — client registrations carry the absolute path of
the binary that ran setup, and setup replaces a registration whose value
differs from what it would write (an identical one is left untouched).
Code this repo with Aubade's own tools:

- Explore with `symbol_list` + `symbol_find` (include_body)
  instead of reading whole files; follow references with
  `symbol_find_references` and call sites with
  `langserver_find_calls`.
- Edit through aubade's editing tools (`symbol_replace_body`,
  `symbol_insert_before`/`symbol_insert_after`, `file_replace`)
  rather than whole-file rewrites.
- At session start, and again after any context compaction, call
  `onboarding_read_instructions` and `onboarding_check`; if onboarding
  hasn't run, run `onboarding_run` first.
- Bug findings are filed with `incident_create` (status starts at
  `reported`) — do **not** write them to memories. An incident must
  report a **reachable** defect: name the triggering path in the
  current tree, not a hypothetical ("if X ever changes...").
  Reports that demand proof of absence — failure modes that require
  a future change to become possible — are not filed at all; the
  concern belongs to the change that makes it real (e.g. a schema
  version gate belongs to the first schema-change commit, not to a
  standing incident). Do not file parking-lot incidents for dormant
  design concerns. Before working on one,
  judge it with `incident_verify` (evidence = file:line + quote); false
  positives are recorded as `verdict=rejected` + `fp_pattern` and kept,
  never deleted. After fixing, re-check the fix, record the root cause
  (`incident_update root_cause`), and only then
  `incident_resolve(resolution="fixed", evidence="commit hash + tests")`.
  Browse with filtered `incident_list`; load full context only via
  `incident_get`. Round work: declare the goal task table's must rows
  (`sprint_start`/`sprint_update` `must`), run each task's verification
  definition and record it with output attached
  (`sprint_record_verification`), and defer what leaves the round as a
  typed defer (`sprint_update` `defer_type=blocked|question|descope`) —
  `sprint_close` refuses on a must task with neither. Unanswered questions
  stay at the top of the tracker summary until answered or descoped
(`sprint_update` note with `resolves=DEF-NNN`). `aubade tracker export`
  re-renders the sprint reports into `sprint_reports` rows in the tracker
  store — no report files are added to the project tree.

# Development rules in detail

## Design rules (code-review criteria)

These are settled structural rules. Violations get flagged in review.

- **Single declaration**: one tool = one `Tool_Desc` definition carrying
  name, description, params, capabilities, and the apply proc. JSON schemas
  and the param-validation proc are generated from it — never hand-write a
  schema or a validator. Tool visibility is one
  pure function, `fold_visibility`, called by **both** hosts (the MCP child
  and hostless consumers like `prompt render`) — do not create a
  second fold implementation (two-consumer regression prevention).
- **Tool names are namespaced** (`<ns>_<verb>[_<object>]`, e.g.
  `symbol_find`, `file_replace`, `incident_create`) and **CLI commands are
  singular noun + verb** with global flags (`--project`,
  `--project-from-cwd`, `--log-level`) defined once at the root. Within the
  noun families one verb per operation (`show` displays one,
  `delete` removes — never `read`/`remove` beside `show`/`delete` for the
  same operation); multi-word subcommands hyphenate (`check-ignore`,
  `fix-references`, `auto-approve`) and the git-style top-level verbs
  (`init`, `setup`, `uninstall`, `about`) stand without a noun by long CLI
  convention. The verb
  slot follows the table's semantic assignment (`get` = fetch one entity,
  `find` = symbol-edge queries like `find_references`/`find_calls`, `read`/
  `list`/`write` by object shape); the `marker_*` family is the one
  declarative exception — markers are capability flags the client answers,
  not actions, so `marker_can_edit` carries no verb by design. Reference
  tool names in code via `Tool_Desc` constants/IDs, never scattered string
  literals. There is **no legacy-name alias map** — unknown tool names in
  configs warn and are skipped by `fold_visibility`.
- **Editing tools set `can_edit: true`** — `read_only` project stripping
  depends on it.
- **symbol_find is precise by default**: no wildcard in the pattern is an
  exact (case-insensitive) name match; `*` turns a segment into a glob
  (`mono_*`, `*_cache`) for discovery. Name-path chains (`Foo/bar`) are
  verified against the indexed parent chain at any depth, a leading `/`
  anchors at the top level, and the workspace/symbol top-up answers pass
  through the same rule — a fuzzy server reply never leaks into the answer.
  The forest-side matcher used by the edit tools stays exact-only; glob
  discovery is an index-tool feature, not an edit-resolution one.
- **Every cache is bounded**: all caches go through `Bounded_Cache` (max
  entries, max bytes). **An unbounded `map` fails review** — and so does an
  unbounded queue: queues are bounded chans, and a full one is refused
  without waiting (the inbound request queue answers RequestFailed and
  keeps reading; the outbound writer queue drops posts past their
  deadline) — load is shed at the source rather than buffered. Data
  (event history, memories) is not capped — the bound is a
  cache-only rule — with one exception shaped like a cache: the editor's
  open-document buffers carry an LRU cap (`EDITOR_MAX_BUFFERS` /
  `EDITOR_MAX_BYTES`) — a daemon-lifetime buffer per distinct edited file
  is unbounded growth; saves are synchronous, so eviction only costs a
  re-read. Symbol resolution is three-tier (SQLite name index,
  per-file sparse payloads in SQLite, bounded hot parse-tree LRU in the
  parent) — the hot ledger charges source bytes **plus tree nodes**
  (`HOT_NODE_BYTES`, calibrated: trees run ~25x their source), so the byte
  cap bounds real memory — and do not add ad-hoc parse-tree caches outside
  that stack.
- **Cache/ownership**: handing a value to `Bounded_Cache.cache_put` with a
  release hook transfers ownership — a `defer`-destroy at the call site
  then double-frees (and a defer inside an `if` fires at block exit, not
  procedure exit). Pick ONE owner.
- **Memory lifetime is rule-bound (no GC)**: request-scope memory lives on
  the request arena and is `free_all`-ed once the apply and its derived
  work complete. An arena-allocated pointer never escapes its lifetime
  scope — data crossing the boundary is copied into the destination
  allocator (cache entries are copy-in). That includes the **keys of
  long-lived maps**: `m[k] = v` stores the key's header without cloning
  its bytes, so a caller-owned key (RPC param, request-arena view, scratch
  buffer) rots once the caller's memory dies — every later lookup misses
  and every `delete_key` silently fails (clone keys on first insert, and
  free the stored key that `delete_key` hands back).
  `context.temp_allocator` is intra-procedure scratch only. C-side
  resources follow the ownership rules: a `TSParser` belongs to its using
  thread; `TSNode`/query matches **borrow** their tree (they must never
  outlive it, and trees in use are not evicted from the LRU); SQLite
  prepared statements are finalized before the connection closes. Freeing
  an object obtained through a map lookup requires an in-use count (or
  unlink-then-destroy) — GC-language prune patterns (`sync.Map.Delete` +
  "nobody holds it now") do not port to manual memory, because a
  just-returned pointer can be pruned before its first use.
  `Safety_Checker`/`Env_Guard` members are value members: init/destroy
  them in place — a heap-constructed guard frees through the tearing-down
  thread's ambient allocator and corrupts the daemon heap.
- **Cancellation lives in the Cancel_Token tree only**: every stop-path API
  (LS stop/restart, buffer flush, project transition) takes a token. Tokens
  are created by `derive` from an existing token only. Do not build
  parallel timeout/stop mechanisms. "A cancel must take effect by the next
  checkpoint" — put checkpoints at blocking waits, LSP round-trips, RPC
  waits, and long CPU loops (per file / per N iterations).
- **Errors are closed per-boundary `Err` values propagated with explicit
  checks** (`if err != nil` / `if cerr != .None` — the codebase idiom;
  `or_return` is not used): no string-matching on error kinds (JSON-RPC/LSP
  error codes
  are typed at the boundary layer). Wrapping must preserve the cause — as a
  `cause` chain link on `platform.Wrapped` when the wrapped failure is a
  platform error, otherwise woven into the message; `err_message` renders
  the chain. Chain links share the wrapper's lifetime scope and never cross
  an RPC boundary. panic is for startup invariant violations only (lookups
  return `.NotFound`).
- **Error type names follow the payload's shape**: a closed failure
  vocabulary as an enum or union takes the `_Err` suffix (`Read_Err`,
  `Call_Err`, `Err_Kind`); a struct explaining a failure's circumstances
  takes `_Error` (`Path_Escape_Error`). `platform.Err` is the canonical
  cross-boundary union; wire-code mirrors keep the `Err_` prefix
  (`Err_Code`); outcome/status carriers (`Call_Outcome`, `Outline_Decline`,
  `Resolve_Status`, `Listen_Result`, `Hook_Outcome`) keep domain names.
- **Path builders swallow allocation errors; security checks fail
  closed**: `filepath.join`/`clean` fail only on allocation failure —
  pure path construction has no other failure mode, so path-construction
  helpers ignore that error channel by design (the empty result surfaces
  at the next os call). Code that makes a *decision* on a path — pathguard
  containment, denylist rule matching, envguard path-like values — must
  check the error and reject/deny instead.
- **Monotonic clocks only** for liveness, timeouts, TTL, and idleness.
  Wall clocks are for display and file names only.
- **Never rewrite user config files as a read side-effect**: config files are
  JSONC (config.jsonc / project.jsonc / project.local.jsonc / contexts /
  modes); generation happens once, from commented templates, via explicit
  commands (init/create family). Machine-written state goes to the
  machine-owned `projects.json` registry or the internal DB kv — never back
  into a user file.
- **The process boundary is real**: child↔parent always goes through the
  svc RPC. Tests and `--in-process` swap in the channel transport instead —
  never fork the implementation into two paths.
- **The rawptr+cast callback pattern**: over 200 uses of `rawptr` across
  src/ (see the README section "Why the source is full of rawptr") are a deliberate
  design decision, not bug avoidance. Two causes: (1) **Odin has no
  closures** — a proc literal cannot capture its lexical scope, so a
  callback that needs state receives it as an explicit
  `proc(data: rawptr, ...)` + `rawptr user` pair (the C callback
  idiom). (2) **Dependency inversion** — lower layers (`tools`, `mcp`,
  `editor`, `platform`) cannot import the host layers (`session`,
  `daemon`), so host handles handed down to callbacks cross the
  boundary type-erased (one field such as `Conn.host` stores several
  concrete host types). Generics (`$T`) cannot replace them: C FFI
  (`void*` required) and the inversion fields erase by construction.
  **Thread entries are the exception**: current core:thread ships
  `create_and_start_with_poly_data` (`proc(data: $T)` — a typed
  facade that still erases into `Thread.data`/`user_args` internally),
  so every thread spawn site in src/ is to migrate to it once the
  toolchain tracks a release newer than dev-2026-09. The few
  theoretically generic cases (`Edit_Job` and
  friends) would only move type safety to the call site, not through
  the framework.
- **Struct field naming**: mutex fields are `mu` (not `mutex`), allocator
  fields are `allocator` (not `alloc` — matches Odin core convention;
  procedure parameters that take an allocator keep the short `a` or a
  role name (`arena`, `scratch`, `walk`, `spec_alloc`) when the role
  matters, but every struct field that holds an allocator is
  `allocator`, including short-lived per-call scratch structs). A
  struct that holds more than one allocator — including through an
  embedded or pointed-to `mem.Dynamic_Arena` (field `arena`) — uses
  role names instead: `owner` frees the struct itself, `allocator` is
  the arena's backing allocator, and `cancel_alloc` marks a dedicated
  cancellation allocator (Registry, Config_Stack, Daemon, App, and the
  dispatch pools are the worked examples). Bool presence/state fields use
  `is_*` for state identification (`is_error`, `is_response`) and `has_*`
  for component presence (`has_body`, `has_include`). The `*_set` family
  (`id_set`, `end_set`, `title_set`, ...) is a separate wire-level
  convention marking that an optional request field was explicitly
  provided by the caller — not drift against `has_*`. Never `have_*`
  (grammatically first-person singular) or bare names where the prefix
  would clarify intent. When a struct has multiple mutexes, the single
  `mu` becomes `*_mu` (`tx_mu`, `doc_mu`); when it has only one, just
  `mu`.

## Testing conventions

- **Isolate AUBADE_HOME**: tests that touch config, contexts, modes, or
  shadow git set `os.setenv("AUBADE_HOME", <temp>)` and restore it on exit
  (no cross-test pollution under parallel runners).
- **No sleeps**: time-dependent logic (heartbeat, grace periods, TTLs,
  timeouts) takes an injected `^Clock`; tests advance time deterministically
  with `Clock_Advance()`.
- **No leaks**: `odin test` runs every test under a tracking allocator and
  prints a `[WARN]` block per leaked allocation — a leak does not fail the
  test, so the rule is **zero leak WARNs** in the suite output. Verify that
  a cancelled request's arena is still `free_all`-ed.
- **fail_now aborts the test without running defers** (as does any panic):
  `testing.fail_now` fires past the defer stack, so a daemon pair or editor
  the test owns leaks — and the leaked threads then corrupt the per-test
  tracking allocator and wedge the whole runner. Never call it while a
  daemon pair or other threaded state is alive: use `expectf` + an early
  `return`, and guard array indexing the same way (a bounds panic skips
  defers too).
- **Fakes live next to the code they fake**: LSP server fake (real wire
  format), MCP client fake, parent fake (channel transport). Real language
  servers (gopls etc.) appear only in the thinnest E2E layer.
- **E2E spawns the real binary**: initialize → tools/list → tools/call over
  stdio MCP. Delete temporary projects/scripts afterwards. Write the
  real-binary driver before trusting in-process greens — in-process
  harnesses miss what only a real spawn shows. Driver-facing facts: the
  project config a session loads is `<root>/.aubade/project.jsonc`, not
  `<root>/project.jsonc` (a misplaced fixture silently runs on defaults);
  `conn_call`'s `deadline_ms` is an absolute monotonic timestamp, not a
  duration; memory names render extension-less in prompts.
- Timing-sensitive suites run with `ODIN_TEST_THREADS=1`.

### Suite verdicts and test drivers

- **`odin test` verdicts come from the log, never the exit status alone** —
  verification is a grep over the suite log for
  `\[ERROR\]|\[FATAL\]|\[WARN\]|\[WARN \]|\+\+\+ leak|bad free|out of range|aubade error:`.
  The **`[WARN ]` and `+++ leak` alternatives are load-bearing**: the
  framework prints its per-test leak blocks under a *padded* header
  (`[WARN ] --- <bytes> :: tests.X`), which `\[WARN\]` alone cannot match.
  So is **`aubade error:`**: the application logger writes
  failures lowercase, which no bracketed pattern matches.
  Tests must never deliberately emit an
  error line — assert the boolean and let the leak-treating callers
  report through `ts_source_log_destroy_refusal`.
  Application-logger `[WARN ]` lines are
  still benign noise; tell them apart by content (`:: tests.` / `+++ leak`
  markers), not by padding. **Always `grep -a`**: a failing render test can
  spill NUL bytes into the log, and grep then treats the whole file as
  binary, silently matching nothing. The leak
  discipline is **zero leak lines** — any leak line is a new finding. Also
  check `free -h` before a suite run and keep a generous margin over the
  compile peak (see Build, test, commit).
- **Never verify a suite run from a detached log-read** — a `setsid`-style
  detach (or any early "completed" signal) can fire while `odin test` is
  still running, and a grep against the compile-phase-only log reads as
  clean while the real run fails or leaks. Run the suite in a tracked
  background task, wait for the `Finished N tests ... All tests were
  successful` line, then grep.
- **Single-test builds (`-define:ODIN_TEST_NAMES=...`) change the binary's
  layout** — reproduce a single-test segfault against the full `just test`
  run before debugging the code.
- **Windows test-driver rules** (1 MB stack, thread lifetime): clone a
  result a caller thread will read into a persistent allocator — never
  read it out of a joined thread's `context.temp_allocator` (the allocator
  dies with the thread). Convert deep-recursion test helpers (500+ levels
  overflow the 1 MB stack) to an iterative work-stack. Give test pipe
  reads a deadline so an unexpected hang cannot wedge the runner.

## Cross-platform file handling

Aubade supports Linux, macOS, and Windows; the rules below keep the tree
portable across all three.

- Put platform differences behind `when ODIN_OS` branches or
  platform-suffixed files (`*_windows.odin` etc. — the convention used by
  core itself). Do not scatter them. A procedure that names a
  platform-suffixed seam's symbols must itself sit inside a `when ODIN_OS`
  block: Odin type-checks unreached procedures, so gating only the call
  site leaves the other targets uncompilable.
- Build paths with the `core:os` filepath procedure group
  (`os.filepath_join` etc.) and the `platform` package's Path type — never
  concatenate separators by hand.
- **macOS terminal sessions default to a 256-file-descriptor soft limit**:
  `odin build`/`odin test`/`odin check` over the full grammar collection
  keep enough files open to exhaust it, and the exhaustion surfaces as
  "Failed to parse file … ( empty line )" and "Unknown error whilst
  reading path grammars:*" errors on the tail imports — indistinguishable
  from missing or corrupt grammars. The justfile's unix recipes and
  scripts/build_install.sh raise the soft limit to 10240 themselves; a
  bare `odin` invocation outside just on a mac needs `ulimit -n 10240`
  first. Linux desktops and CI runners carry far higher defaults and
  never hit this.
- **macOS/Windows filesystems are case-insensitive**: compare and dedup
  paths with the platform's case-insensitive helpers, never with `==`.
- **The project root's canonical spelling is symlink-resolved at every
  entry point** (`safety.pathguard_resolve_root` in `daemon_init`, the session
  before the daemon-dir id is hashed, the `daemon` control commands, and
  the LSP client's `root_abs`): the path guard hands out resolved paths,
  and macOS temp trees sit behind `/var -> /private/var`, so a
  raw-spelled root fails every prefix compare against guard-produced
  paths — the child/daemon endpoint id, doc-sync URIs, and URI
  relativization all share the one canonical spelling. Never compare a
  caller-supplied root spelling lexically against guard outputs; resolve
  first or compare rel paths. Darwin clock ids are NOT Linux's:
  `CLOCK_MONOTONIC` is 6 on darwin (1 is invalid — clock_gettime returns
  EINVAL and a zero clock silently freezes every deadline loop).
- CRLF vs LF follows the project's `line_ending` setting. The editor
  preserves the existing encoding (UTF-8/UTF-16/latin-1) — it never
  re-encodes silently.
- Permissions go through the platform permission helpers (advisory on
  Windows).
- Pre-commit check on Linux: `just check` + `just test`. Three-OS
  verification is done on the **CI matrix (ubuntu / macos / windows
  runners)**, not via cross-compilation (Windows is MSVC native builds
  only). This rules out local `odin check -target:<other-os>` runs and
  per-package cross-target checks as "verification" steps: anything aimed
  at another OS belongs to the CI matrix — locally, only native-Linux
  `just check` + `just test` count.

## Build, link, and check

- **Many distinct `foreign import` paths drop every .a from the link**
  (seen on dev-2026-08 nightlies; not re-verified since — the merged
  archive below is retained regardless): once a build carries on the
  order of 200 distinct
  foreign-library import paths, the compiler emits a link line with none of
  them — thousands of undefined references that look like a missing
  artifact. The grammar registry works around it by merging all grammar
  objects into one `libtree-sitter-grammars.a` whose bindings all import
  the identical relative string (deduped to a single `-l:` entry); keep
  that pattern when adding foreign libraries at scale.
- `foreign import` uses paths relative to the .odin file plus
  `when ODIN_OS`/`ODIN_ARCH` branching (the lib/<os>_<arch> directories
  tools/build produces; anything outside windows/darwin/linux on
  amd64/arm64 fails with a #assert at the seam). Every `foreign` block carries
  `@(default_calling_convention = "c")` (the sqlite/pcre2 pattern —
  libSystem blocks and link-prefixed tree-sitter blocks included). If the
  build fails on missing C artifacts, run `just build` first.
- The per-directory `just check` compiles packages with `-no-entry-point`
  and no consumers: imports used only inside generic definitions are
  flagged unused. `src/util/cache.odin` carries a private instantiation
  anchor for exactly that.

## Config, deployment, and spec

- `blocked_shell_commands` / `allowed_shell_commands` are **regex patterns**
  matched against the normalized full command line, not literal command
  names.
- Client registrations point at the installed `aubade` binary — reinstall
  and re-register after changes, or already-attached sessions keep running
  the old binary.
- The MCP protocol baseline is the 2025-11-25 revision on modelcontextprotocol.io.
  Before touching anything spec-related, re-check the changelog of the current
  revision on the spec site.

# Reference

## Odin language and stdlib

- Odin `defer` fires at the end of the enclosing **scope**, not the procedure:
  a `defer` inside an `if`/`when` block runs when that block exits — long
  before the rest of the procedure. For must-run-on-return cleanup, hoist a
  flag and use a procedure-scope `defer if flag { ... }`.
- `append` on a nil (zero-value) `[dynamic]` grows it through
  `context.allocator` — under `odin test` that is the per-test tracking
  allocator, and the stranded backing surfaces as a leak WARN. Create
  dynamic arrays with `make([dynamic]T, 0, cap, a)` before appending: a
  made array carries its allocator, and later `append`s grow through it.
- The same auto-init rule applies to **zero-value maps** (first insert grows
  through `context.allocator`) — a long-lived struct that owns maps or
  dynamics must `make` every collection on its own allocator in its init
  (`tracker.fold_state_init` is the worked example; in tests the two
  allocators coincide, so the bug only surfaces in production).
- A plain `[]T` made with an explicit allocator carries nothing — freeing
  it needs `delete(x, that_allocator)`; `delete(x)` frees through
  `context.allocator` and is a bad free in any non-test caller.
- The same applies to **strings** (cloned with `strings.clone(s, a)`, freed
  with `delete(s, a)` — a bare `delete(s)` is a bad free whenever
  `context.allocator != a`).
- The mirror-image fact: a
  **`[dynamic]T` or `map` made with `make(..., a)` carries its allocator
  in the value, and bare `delete(x)` frees through the STORED
  allocator** — those sites are correct as written; only `string`/`[]T`
  deletes fall back to `context.allocator`.
- The inverse case: a `[]T{...}` literal whose elements are all
  compile-time constants is placed in **static data** — `delete` on it
  is an immediate bad free (leave constant literals undeleted).
- **`strings.builder_make_len(n)` makes a zero-filled buffer of LENGTH
  n** (writes append *after* the zeros, so rendered strings come out
  NUL-prefixed). Reserve capacity with
  `strings.builder_make_len_cap(0, n, a)`. And `strings.to_string(b)`
  returns a **view** into the builder's buffer — with a
  `defer builder_destroy` in scope the view dies at procedure exit, so
  clone out (`strings.clone(strings.to_string(b), a)`) before returning.
- **`core:path/filepath` defects on this nightly**:
  `filepath.abs` returns `""` for input it cannot stat (e.g. a nonexistent
  path — the error channel does carry `Not_Exist`, which callers that
  discard it never see), and `dir("")`/`dir(".")` return `"."`/`""` respectively — so a
  peel loop that follows `dir` until it converges never terminates on such
  input (it cycles `""`↔`"."`, appending forever). Use already-cleaned absolute
  paths directly, never feed `abs` output forward unchecked, and bound any
  `dir`-walking loop explicitly. Also note Odin `int` is pointer-sized
  (64-bit on x86_64): `cast(int)(uintptr(p))` is a lossless bit conversion,
  **not** a C-style 32-bit truncation.
- **Odin syntax that differs from C and Go**:
  - `'abc'` is a RUNE literal — strings are always `"abc"` (escape
    inner quotes)
  - `case:` in a `switch` over an enum/union is NOT a default unless
    the switch is `#partial` (full switches must enumerate)
  - `+` string concatenation works only on compile-time constants —
    runtime joins go through `strings.concatenate`
  - procedure parameters are immutable (copy into a local to mutate)
  - `for v, i in slice` binds value-then-index (a `for _, x in` binds
    the INDEX to x — double-check before using x)
  - indexing a `::` constant with a variable index is a compile error
    ("Cannot index a constant" — dev-2026-09) — bind the constant to a
    local (`table := TOOLS`) and index that, or iterate it with a for
    binding
  - `builtins: $T` passed `[]Context_Def` binds T to the SLICE — write
    `builtins: []$T` to bind the element
  - `append(&dyn_u8, some_slice)` is ambiguous — append strings or
    elements
  - `fmt` treats `{` in any string it formats (including through
    `%q`/testing.expect_value) as a parameter brace — build JSON with
    plain concatenation and compare with `==`, not expect_value
  - `strings.join` returns an optional allocator error
  - `for c in some_string` iterates RUNES — index bytes (`s[i]`) when
    appending to a `[]u8` buffer
  - never return a string/view into a local stack buffer (clone out)
  - a struct field named identically to an imported package (e.g. a
    `mem` field in a file that imports `core:mem`) is an "Illegal
    declaration cycle" — rename the field
  - `for x in []T{...} {` cannot parse the literal's brace — bind the
    literal to a local (or constant) first
  - a `Dynamic_Arena` is self-referential: never return or copy one by
    value out of the procedure that initialized it — declare
    `arena: mem.Dynamic_Arena` inline where it is used
- **Constant-struct data is safe to copy on dev-2026-09** (guard tests
  `builtin_modes_use_new_names` / `context_user_overrides_builtin` /
  `web_search_range_enum_intact` remain as regression canaries). What
  persists as a hard rule: variable indexing straight into constant
  data is rejected by the compiler (see the syntax list above), so
  tables are materialized into a local before indexed use — an
  idiom, not a workaround.
- **`when`/`else` inside a generic**: else-less `when` arms are safe; where
  a branch must not cross-check for some `T`, thread the per-type proc as
  a parameter instead (the `load_resource` shape, by design).
- **Core os procs allocate through the allocator you pass — a discarded
  result is an instant leak**: `os.stat`/`os.lstat` clone
  `File_Info.fullpath` and `os.read_link` its target with the passed
  allocator (free via `os.file_info_delete` or `delete`); `os.environ`,
  `os.make_directory_temp`, and `os.lookup_env_alloc` return owned
  clones the caller must delete. Two shapes pass review: use-then-delete
  at the call site, or run the whole procedure's scratch on
  `context.temp_allocator`/an arena and clone only what escapes into the
  caller's allocator (aubade_home and pathguard's symlink walk are the
  worked examples; the web converters do the same on a Dynamic_Arena
  with the ambient allocators scoped to it). Never `_, err := os.lstat(...)`
  with a non-temp allocator.
