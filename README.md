# Aubade

A symbol-level code intelligence server built on the Language Server Protocol, exposed via the Model Context Protocol.

Named after the poetic form called the aubade — a song about lovers parting at dawn. The best-known example comes from Shakespeare's Romeo and Juliet (III.v), where Juliet tries to convince Romeo that the bird they hear is the nightingale, not the lark — that it is still night and not yet morning:

> *Wilt thou be gone? it is not yet near day:*
> *It was the nightingale, and not the lark,*
> *That pierc'd the fearful hollow of thine ear.*

LLMs make the same mistake Juliet makes: they hear what they want to hear. They hallucinate functions that don't exist, misread call chains, and confuse the structure of the code in front of them. They mistake the lark for the nightingale. Aubade provides the ground truth — symbol definitions from LSP, AST structure from tree-sitter, safe rollback via shadow git — so that when the LLM insists it's still night, you have the dawn to prove otherwise.

## Quick start

```bash
# Build from source: clone with submodules (lexbor lives in one):
#   git clone --recurse-submodules <repo-url>
# Requires the Odin compiler (latest nightly, odin-lang.org), `just`,
# and a C/C++ toolchain.
just build

# Build and install in one step:
sh scripts/build_install.sh

# Initialise global configuration
aubade init

# Register with your AI client
aubade setup claudecode    # or: codex / opencode / qwen / zcode
```

The install script needs the C artifacts under `lib/` that
`just build` produces; with a plain `just build` you instead put the
repository-root binary on your `PATH` yourself. Install destinations,
`AUBADE_INSTALL_DIR`, and the Windows procedure —
`scripts\build_install.ps1` from a Visual Studio developer prompt —
are in [Building from source](#building-from-source) and
[docs/windows-build.md](docs/windows-build.md).

For manual MCP configuration, the server command is:

```json
{
  "mcpServers": {
    "aubade": {
      "command": "aubade",
      "args": ["mcp", "--context", "agent", "--project-from-cwd"]
    }
  }
}
```

MCP is served over stdio. Every CLI command accepts three global flags: `--project <path-or-registered-name>`, `--project-from-cwd`, and `--log-level <DEBUG|INFO|WARNING|ERROR>`.

Client-by-client setup, hooks, and the full configuration reference live in [docs/](docs/index.md).

## How it works

Aubade serves symbol-level code intelligence from two engines:

- **Tree-sitter (primary)**: symbol search (`symbol_find`, `symbol_list`) runs fully in-process from bundled grammars — no language server involved, so it works instantly at session start and keeps working when a server crashes. For any language with a bundled grammar, tree-sitter takes priority; the language server is consulted for symbol search only when the tree-sitter pass yields nothing (a language without a grammar, or an outline that came back empty) — never when it returns symbols.
- **Language servers (semantic, lazy)**: references, implementations, declarations, diagnostics, code actions, formatting, inlay hints, and call hierarchy — plus symbol search for languages tree-sitter does not serve — start the matching language server on first use and keep it alive while idle. When a server dies, the next call replaces it; a failed start arms a short cooldown, so a broken toolchain cannot fork-bomb.

In mixed-language projects, languages without a bundled grammar (e.g. Lean) still appear in directory- and project-wide symbol searches through whatever language servers are already running — broad searches never *start* servers, they only use running ones, so a project-wide `symbol_find` cannot fan out into dozens of server launches.

```
┌─────────────┐      MCP (stdio)         ┌──────────────────────────┐    LSP (JSON-RPC)     ┌──────────────────┐
│  AI agent   │ ◄─────────────────────── │         Aubade           │ ◄──────────────────── │  gopls,          │
│  (Claude,   │                          │  ┌────────────────────┐  │   (lazy start,        │  rust-analyzer,  │
│  OpenCode,  │                          │  │ tree-sitter        │  │    semantic ops       │  typescript-     │
│  ZCode...)  │                          │  │ symbol engine      │  │    only)              │  language-server │
└─────────────┘                          │  └────────────────────┘  │                       └──────────────────┘
                                         └──────────────────────────┘
                                               │
                                        ┌──────┴──────┐
                                        │   SQLite +  │
                                        │  hot-tree   │
                                        │ LRU (disk + │
                                        │  in-memory) │
                                        └─────────────┘
```

Symbol resolution is three-tier: a SQLite name index answers name queries without parsing anything; each file's symbol forest is persisted as a compact payload in SQLite, with a bounded in-memory mirror in front; and a bounded LRU keeps hot parse trees in the daemon's memory so follow-up work on recently-touched files skips re-parsing. The on-disk index survives restarts, and every cache is bounded by entries and bytes — the full resident-memory budget, its ledgers, and how the parse-tree charge is calibrated are specified in [docs/memory.md](docs/memory.md). The full architecture (lookup flow, crawl, freshness heal, edit propagation) is in [docs/symbol-engine.md](docs/symbol-engine.md).

### Memory containment

Language servers can allocate aggressively (gopls type-checking a large workspace is the classic case) and, left unbounded, can take the whole machine down with them. Aubade caps every language server process at the OS level:

- **Linux**: each server runs in its own cgroup v2 directory with `memory.max` (hard limit), `memory.swap.max=0`, and `memory.oom.group=1`. Enforcement is synchronous in the kernel, so it holds no matter how fast the server allocates. Requires a delegated cgroup subtree (systemd user delegation).
- **macOS**: a best-effort RSS watchdog kills the server's process tree when it exceeds the limit. Polling cannot fully outrun very fast allocation; it is a safety net, not a guarantee.
- **Windows**: each server runs inside an anonymous kernel Job object with a job-wide memory ceiling and kill-on-job-close: past the cap the tree's allocations fail (kernel-enforced at commit time — no OOM-kill flavour to ask for), and the daemon's death closes the last job handle, taking every member down with it. The Job path is the newest of the three and has seen the least real-world use.
- Limits are built-in defaults, not config keys: a multi-gigabyte ceiling per server, with extra headroom for gopls — which also gets a soft `GOMEMLIMIT` so the Go runtime paces itself before the hard ceiling.
- When a contained server hits the limit and is killed, aubade's restart machinery brings it back on the next call.

Known containment caveats: without a delegated cgroup subtree — common in unprivileged user sessions — aubade logs a warning and runs the server without a hard limit rather than failing to start; and cgroup directories are removed when a server exits normally, but if aubade itself is SIGKILLed the (empty, still-limited) directories remain under the delegated subtree.

This section caps *language servers*. For aubade's own resident-memory budget, see [docs/memory.md](docs/memory.md).

### Tree-sitter symbol engine: known limitations

- Most bundled grammars ship highlight queries only, so their tags queries are inferred from generic node shapes. Aubade maintains full outline-query overrides for Go, Odin, and TypeScript (whose inference missed most Odin declarations and TypeScript variables/fields) and hand-verified inference overrides for about 40 more languages; other inference-served languages can miss language-specific declaration forms.
- Rust `impl`-block methods surface as top-level functions (`new`, not `Server/new`): owner nesting is driven by receiver resolution, which is currently Go-only.
- A single-line multi-name declaration (`var a, b = 1, 2` in Go) is dropped rather than half-captured; one declaration per line is unaffected.
- Go type aliases are classified by the `type` keyword's declaration text, so `type R = io.Reader` reports Struct where gopls reports Interface.
- Markup and data languages (JSON, YAML, HTML, CSS, …) have no symbol outline: `symbol_list` answers empty for them, and nothing in the response distinguishes "no symbols" from "language not served". JSON-family and YAML files do get a structural face — `file_read_outline` renders their key tree and extracts jq-style paths — but the remaining markup/data languages are plain text to both engines.
- Cross-file `symbol_find` is an index read. The daemon warms the index with a whole-project crawl at startup, and out-of-band file changes — an agent's own writes, git checkout, scripts — are discovered without waiting for it: an answer that would come back empty triggers one rate-bounded incremental discovery walk before it is returned, and a background loop re-walks the project periodically as a hygiene floor. The crawl skips a shared built-in ignore list (`.git`, `node_modules`, build caches, …) and gitignored paths, does not follow symlinks, and is capped (file count, depth, per-file size); files outside the caps (or in ignored paths) still appear once read via `symbol_list`, which indexes as a side effect. The full freshness model is specified in [docs/symbol-engine.md](docs/symbol-engine.md).

### Why the source is full of `rawptr`

Odin has no closures: a procedure literal cannot capture the lexical
scope around it, so every callback that needs state receives it as an
explicit `rawptr` parameter and casts it back at the receiving end — the
same pairing C libraries have always used. Three forces keep the count
high (over 200 occurrences in `src/`): `core:thread` carries worker
state as erased pointers at its core, the C interfaces (tree-sitter,
SQLite, PCRE2) pass `void *` user payloads through their callbacks, and
non-host packages must hand host handles down across the layer boundary
type-erased. Generics cannot replace most of these (a `$T` procedure
value still captures nothing, and the FFI signatures are fixed), so the
erased-pointer pairs are the deliberate shape of the design, not
untyped shortcuts.

## Process model

One binary, two roles:

- **MCP child** (`aubade mcp --project <path>`) — one lightweight process per client session. It speaks MCP over stdio and forwards all work to the daemon over a local RPC.
- **Daemon** (one per project, spawned on demand, singleton via a lock) — owns the language-server clients, tree-sitter caches, editor buffers, the SQLite store, and shadow git. It outlives individual sessions: the next session reconnects to warm caches and already-running language servers, and the daemon exits on its own once the last child disconnects.

`aubade daemon status` reports the pid, port, and connected children; `aubade daemon stop` is refused while sessions are still connected.

Project state lives under `<project>/.aubade/`: `project.jsonc`, `aubade.db` (SQLite — the symbol index, per-file symbol payloads, the append-only tracker event log, and the rendered sprint reports the tracker exports), `memories/` (project memory notes). The global home is `~/.aubade`, overridable with `AUBADE_HOME`: `config.jsonc`, `contexts/`, `modes/`, the machine-owned `projects.json` registry, global `memories/`, per-project `daemon/` runtime directories, shadow-git `snapshot/` repositories, and `hook_data/` for the client hooks.

## Tools

Aubade's tools fall into the groups below; `aubade tool list` previews exactly what a session would see once contexts and modes are applied.

**Symbol operations** — `symbol_list`, `symbol_find`, `symbol_find_dead_code`, `symbol_find_references`, `symbol_find_implementations`, `symbol_find_declaration`, `symbol_replace_body`, `symbol_insert_before`, `symbol_insert_after`, `symbol_move`, `symbol_rename`, `symbol_delete`, `symbol_insert_docstring`, `symbol_delete_docstring`, `symbol_replace_docstring`

`symbol_find_dead_code` reports definitions that are almost surely dead inside the project: a whole-project scan counts every textual occurrence of each definition name (comments, strings, prose included — the whole text tree, not just source), and a candidate is a name that never occurs outside its own declaration spans. Same-name definitions keep each other alive (precision over recall), convention-invoked names are excluded (attributes/decorators above a definition; entry prefixes, default `test_`/`Test`/`main`), and the answer is a review queue — "dead" means unused within this project, and consumers outside it are invisible.

**File operations** — `file_read`, `file_write`, `file_list_dir`, `file_find`, `file_search`, `file_read_outline`, `file_replace`, `file_insert_lines`*, `file_replace_lines`*, `file_delete_lines`*, `file_delete`, `file_move`

`file_read_outline` reads JSON/JSONC/JSON5/YAML structurally instead of grepping: without a `path` it renders an indented key tree with 0-based line numbers and clamped value previews; with a jq-style path (`.a.b[0].c`, quoted keys via `."odd key"` or `["odd key"]`, negative indexes, a terminal `[]` or `| keys`) it returns the exact value(s) at that path with their line range. The line numbers feed `file_read`/`file_replace` ranges directly; malformed files fail loudly with the first error row.

**AST operations** — `ast_parse`, `ast_query`, `ast_find_duplicates`

`ast_find_duplicates` reports duplicated code deterministically from tree-sitter structure: a whole-project scan hashes every named subtree of at least `min_nodes` nodes over its full shape — comments and formatting never reach the hash, operators do — and groups equal hashes into clones. `exact` covers identical fragments; `renamed` covers copy-paste under a consistent identifier renaming with literal values abstracted, so a partial rename that collapses two names into one does not match. Groups report maximal clones only (interior blocks of a larger duplicate do not re-report), occurrences are 0-based inclusive line spans, and the answer is byte-identical across runs. `path_prefix` filters the report; the scan always covers the project.

**Memories** — `memory_write`, `memory_read`, `memory_list`, `memory_replace`, `memory_rename`, `memory_delete`

Memories are persistent markdown notes under `<project>/.aubade/memories` (project) and `~/.aubade/memories/global` (shared, addressed by the `global/` name prefix). The onboarding flow surfaces them in the session prompt; `read_only_memory_patterns` / `ignored_memory_patterns` pin or hide entries (see [docs/configuration.md](docs/configuration.md)).

**Incident tracker** — `incident_create`, `incident_verify`, `incident_update`, `incident_resolve`, `incident_delete`, `incident_list`, `incident_get`, `sprint_start`, `sprint_close`, `sprint_update`, `sprint_record_verification`, `sprint_list`, `sprint_get`, `tracker_export`

An event-sourced bug and audit tracker scoped to the project. Incidents are filed as `reported`, judged with `incident_verify` (false positives are kept as data for FP statistics, never deleted), and resolved only after the root cause has been recorded. Work happens in sprints: a sprint declares its must-do tasks up front, each task earns verification records (the latest one wins), and closing is refused while a must task has neither a passing verification nor a typed defer (`blocked`/`question`/`descope`). The event log is the source of truth; the CLI can query it without an MCP client (`aubade tracker list/show/report`; `tracker export` re-renders the sprint reports into `sprint_reports` rows in the SQLite store — no files are added to the project tree). `read_only` projects strip the tracker's writing tools.

**Language servers** — `langserver_list`, `langserver_get_diagnostics`, `langserver_get_code_actions`, `langserver_format`, `langserver_get_inlay_hints`, `langserver_find_calls`; management `langserver_start`*, `langserver_stop`*, `langserver_restart`*, `langserver_reload`*

**Shadow git (optional)** — `shadow_snapshot`, `shadow_log`, `shadow_diff`, `shadow_patch`, `shadow_restore`, `shadow_revert_file`

Shadow git keeps workspace snapshots in a private git repository under the aubade home, separate from the project's own git history. `shadow_snapshot` records one and returns its commit hash; `shadow_log`, `shadow_diff`, and `shadow_patch` inspect and export them; and `shadow_restore` / `shadow_revert_file` roll the workspace — or a single file — back, passing the same containment and write-denial gate as file writes.

**Web (optional)** — `web_fetch`, `web_search` (needs a search provider in `config.jsonc`: Brave, Tavily, Perplexity, DuckDuckGo, or SearXNG)

**Onboarding** — `onboarding_check`, `onboarding_read_instructions`, `onboarding_run`

**Shell** — `shell_run`

**Project configuration** — `config_get`, `config_set`, `config_delete`

**Capability markers (optional)** — `marker_symbolic_read`, `marker_can_edit`, `marker_symbolic_edit` — no-op tools that let a context's prompt key on what the client grants

Optional tools — the ones marked `*` above, plus the shadow-git, web, and marker groups — stay hidden until included via `included_optional_tools` (or the whole set is pinned with `fixed_tools`) in the global config, a context, a mode, or a project. `read_only` projects strip every file-modifying tool, including the config write pair.

## Configuration

Everything is JSONC — JSON with comments. Files are generated once from commented templates by explicit commands and are never rewritten as a side effect of reading them; aubade rewrites only its own machine-owned state (`projects.json`, the database).

### Global (`~/.aubade/config.jsonc`)

Created by `aubade init` (write-once: init refuses to overwrite an existing file). Shared across all projects. Notable keys: `default_modes`, `tool_timeout`, the tool-visibility triple `excluded_tools` / `included_optional_tools` / `fixed_tools`, `blocked_shell_commands` / `allowed_shell_commands` (regex patterns matched against the normalized full command line), and the `web` block (search-provider credentials, fetch proxy, host rules).

### Project (`.aubade/project.jsonc`)

Created by `aubade project create .`. Per-project language servers, ignore rules, and tool settings:

```jsonc
{
  "project_name": "my-app",
  "language_servers": [
    {"name": "go"},
    {"name": "odin", "path": "~/.local/bin/ols"}
  ],
  "ignored_paths": ["internal/generated/**"],
  "read_only": false
}
```

### Language servers

`language_servers` names the servers to start, one object per server: `{"name": <language id>, "path": <server binary>}`. `name` is the language id (`"go"`; for C use `"cpp"`, for JavaScript `"typescript"`); `path` designates the server binary's OS location — absolute (keeps working when the client scrubs the environment), `~/`-anchored, or project-root-relative; omitted means normal `PATH` resolution. Servers needing extra arguments take a full argv in `language_server_commands`, and initialization options go in `language_server_options`; all three keys apply live through `config_set` / `langserver_reload`. Path-form details, resolution precedence, and memory containment: [docs/configuration.md](docs/configuration.md#language-servers). `eager_language_servers: true` in the global config restores starting all servers at session start instead of on demand.

### Local override (`.aubade/project.local.jsonc`)

Developer-specific overrides of the project config — create it by hand and keep it out of version control.

### Contexts and modes

**Contexts** adapt tool descriptions and visibility for specific MCP clients (`--context zcode`, `--context claudecode`, …). Built-in contexts cover common clients (`desktop-app` is the default); a context marked `single_project: true` pins the server to the project resolved at startup and drops `config_get`. Custom contexts live in `~/.aubade/contexts/`; `aubade context create --from-internal <name>` starts from a copy of a built-in. The full inventory, per-client guidance, and known client issues: [docs/configuration.md](docs/configuration.md#contexts) and [docs/harnesses.md](docs/harnesses.md#choosing-a-context).

**Modes** are named presets that exclude tools and inject prompts. Built-ins: `editing` and `interactive` (the defaults), `planning`, `onboarding`, `no-onboarding`, `one-shot`, and `no-memories`. Activated via `default_modes` in the global config or `added_modes` per-project; custom modes go in `~/.aubade/modes/`.

## Supported languages

Language servers for the languages you are likely to work with are configured out of the box: Go (gopls), Python (pyright, with jedi and ty alternates), TypeScript (typescript-language-server, with vtsls), Rust (rust-analyzer), Java (jdtls), C/C++ (clangd), C#, Ruby (ruby-lsp), Swift (sourcekit-lsp), Scala (metals), Kotlin, Haskell, Elixir, Lua, Zig (zls), Odin (ols), Terraform, and more. Symbol search runs on the bundled tree-sitter grammars (including Go, TypeScript, Python, Rust, Java, C#, Kotlin, Dart, Zig, and Odin) — a language server is consulted only for languages without a grammar (see [How it works](#how-it-works)).

## Safety

- **Path containment**: every path is cleaned and resolved — symlinks included — and must stay inside the project root and the configured workspace folders; the check fails closed.
- **Sensitive reads**: reading credential-like paths (`.env`, key and token files, … — a built-in list) is gated by a read-ask heuristic: the tool response tells the model to confirm with the user first.
- **Shell**: commands are matched against the `blocked_shell_commands` / `allowed_shell_commands` regex rules and run with a scrubbed environment.
- **Web**: `web_fetch` / `web_search` go through a URL guard — private hosts are denied unless `allow_private_hosts` is set, and `whitelist_hosts` can pin the allowed set.
- **No telemetry**: aubade's own code contains no analytics, crash reporting, or update checks, and never sends data anywhere on its own. The only outbound network requests are the ones you explicitly make via `web_fetch` / `web_search` — to the URLs you fetch and the search provider you configure. All state (symbol index, tracker, memories, shadow git) stays in `~/.aubade` and `<project>/.aubade/` on your machine.

## CLI reference

```
aubade init                                           Initialise global configuration
aubade mcp [--project <path>]                         Start an MCP session (stdio)
aubade daemon status | stop                           Inspect or stop the project daemon
aubade setup <client>                                 Register with a client: claudecode, codex, opencode, qwen, zcode
aubade uninstall <client>                             Remove the registration (inverse of setup)
aubade project create|list|index|delete|check-ignore|doctor    Manage projects
aubade tool list | show <name>                        Inspect the tool table and folded visibility
aubade memory list|show|write|check|fix-references    Manage memories
aubade tracker list|show|export|report                Inspect incidents and sprints (report prints TSV/JSON)
aubade prompt render|list|show                        Render and inspect system prompts
aubade prompt override list|create|edit|delete        Manage prompt-template overrides
aubade context list|create|edit|delete                Manage contexts
aubade mode list|create|edit|delete                   Manage modes
aubade config edit                                    Edit config.jsonc in $EDITOR
aubade hook activate|cleanup|remind|auto-approve      Client hook helper (claudecode, codex, vscode)
aubade about                                          Print version, licence, and vendored components
```

## Relationship to Serena

Aubade's design reference is the MCP tool interface of [oraios/serena](https://github.com/oraios/serena); it shares no code with Serena and reaches a similar feature set by different means, under its own namespaced tool names (`symbol_find`, `file_replace`, `incident_create`, …) rather than Serena-compatible ones. `aubade tool list` shows the current surface.

Notable differences:

- A single static binary written in Odin — no Python runtime; the bundled grammars dominate the on-disk size but never slow startup
- A per-project daemon keeps language servers, caches, and the SQLite symbol store warm across sessions
- Three-tier symbol resolution: a SQLite name index, per-file sparse symbol payloads in SQLite, and a bounded hot parse-tree LRU
- OS-level memory containment for language servers (cgroup v2 on Linux, an RSS watchdog on macOS, kernel Job objects on Windows)
- Shadow git for workspace snapshots and rollback
- A built-in incident tracker with verification records and per-sprint reports

## Building from source

Prerequisites and the clone step are in the [Quick start](#quick-start).
The first `just build` compiles the bundled tree-sitter grammars into
`lib/` and is slow; later builds are incremental. From there, two ways
to put the binary on your machine:

- **Install script** — `sh scripts/build_install.sh` (Linux/macOS)
  builds and installs to `~/.local/bin`; on Windows,
  `scripts/build_install.ps1` installs to
  `%LOCALAPPDATA%\Programs\aubade` and adds the directory to the user
  PATH. `AUBADE_INSTALL_DIR` overrides the destination on both. The
  scripts need the C artifacts under `lib/`, so run `just build`
  first; they warn when a different `aubade` resolves earlier on PATH.
- **Manual** — a plain `just build` leaves the `aubade` binary at the
  repository root; copy it anywhere on your `PATH` yourself.

Windows-specific build details are in
[docs/windows-build.md](docs/windows-build.md).

## Requirements

- Language servers for the languages you work with — optional; symbol search needs none of them
- Linux, macOS, or Windows

## Contributing

Bug fixes are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
guidelines on new features and the release cadence.

## Licence

MIT — see [LICENSE](LICENSE).

Third-party components (SQLite, PCRE2, lexbor, tree-sitter and its
grammars) — acknowledgments, pins, and licences:
[third_party/README.md](third_party/README.md); the per-grammar licence
notice is [docs/licenses.md](docs/licenses.md); `aubade about` prints the
summary at runtime.
